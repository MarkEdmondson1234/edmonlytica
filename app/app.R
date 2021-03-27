library(shiny)
library(bigQueryR)
library(highcharter)
library(xts)
library(forecast)
library(dplyr)
library(shinythemes)
library(DT)

realtime_q <- 'SELECT * EXCEPT(ts), 
    ts AS timestamp FROM `edmonlytica.code_markedmondson_me` 
    ORDER BY ts DESC'

refs <- 'SELECT
  page,
  referrer,
  ts AS timestamp,
  COUNT(DISTINCT sessionId) AS visits
FROM
  `edmonlytica.code_markedmondson_me`
WHERE
  event = "gtm.js"
  AND page is not NULL
  AND referrer IS NOT NULL AND referrer != ""
  AND NOT STARTS_WITH(referrer, "https://code.markedmondson.me") 
  AND _PARTITIONDATE BETWEEN "%s" AND "%s"
GROUP BY
  page, referrer, timestamp'

pvs <- 'SELECT ts AS timestamp, 
         page,
         count(1) as pageviews
FROM 
  `edmonlytica.code_markedmondson_me` 
WHERE 
  event = "gtm.js" 
  AND page IS NOT NULL
  AND _PARTITIONDATE BETWEEN "%s" AND "%s"
GROUP BY 
  timestamp, page'


do_bq <- function(q, limit=10000, cache = TRUE){
    
    q <- paste(q, " LIMIT ", limit)
    
    if(!googleAuthR::gar_has_token()){
        # auth on Cloud Run
        googleAuthR::gar_gce_auth()
    }
    
    if(!cache) googleAuthR::gar_cache_empty()
    
    o <- bqr_query(projectId = Sys.getenv("BQ_DEFAULT_PROJECT_ID"), 
              datasetId = "edmonlytica", 
              query = q, 
              useQueryCache = cache,
              useLegacySql = FALSE) 
    o$timestamp <- as.POSIXct(
        as.numeric(o$timestamp)/1000, origin="1970-01-01")

    o
}

get_bq <- function(){
    message("Getting new data...")
    do_bq(realtime_q, 1000, FALSE)
}

check_bq <- function(){
    check <- do_bq(realtime_q, 1, FALSE)
    message("Checking....check$ts: ", check$timestamp)
    check$timestamp
}

transform_rt <- function(rt){
    ## aggregate per hour
    rt <- rt[complete.cases(rt), ]
    rt_agg <- rt %>% 
        mutate(hour = format(timestamp, format = "%Y-%m-%d %H:00")) %>% 
        count(hour)
    
    rt_agg$hour <- as.POSIXct(rt_agg$hour, origin="1970-01-01")
    
    # ## the number of hits per timestamp
    rt_xts <- xts::xts(rt_agg$n, frequency = 24, order.by = rt_agg$hour)
    rt_ts <- ts(rt_agg$n, frequency = 24)
    
    list(forecast = forecast::forecast(rt_ts, h = 12),
         xts = rt_xts)
}

bq_daterange <- function(q, start, end){
    q <- sprintf(q, start, end)
    do_bq(q)
}

ui <- fluidPage(theme = shinytheme("sandstone"),
    titlePanel(title=div(img(src="green-hand-small.png", width = 30), "Edmonlytica")),
    sidebarLayout(
      sidebarPanel(
        dateRangeInput("dates", "Date Range", 
                       start = Sys.Date() - 90, end = Sys.Date()) 
      ),
      mainPanel(
        tabsetPanel(
          tabPanel(
            "Pageviews",
            highchartOutput("pvs_chart")
          ),
          tabPanel("Referrals",
                   DT::dataTableOutput("referral_table")  
          ),
          tabPanel("Realtime hits forecast",
                   highchartOutput("rt_chart")
          )
        )
      )
    )
)

# Define server logic required to draw a histogram
server <- function(input, output, session) {
  
    ## checks every 5 seconds for changes
    realtime_data <- reactivePoll(5000, 
                                  session, 
                                  checkFunc = check_bq, 
                                  valueFunc = get_bq)
    
    rt_data <- reactive({
        req(realtime_data())
        rt <- realtime_data()
        message("plot_data()")
        ## aggregate
        transform_rt(rt)
    })
    
    output$rt_chart <- renderHighchart({
        
        req(rt_data())
        ## forcast values object
        fc <- rt_data()$forecast
        
        ## original data
        raw_data <- rt_data()$xts
        
        # plot last 48 hrs only, although forecast accounts for all data
        raw_data <- tail(raw_data, 24*7)
        raw_x_date <- as.numeric(index(raw_data)) * 1000
        
        ## start time in JS time
        forecast_x_start <- as.numeric(index(raw_data)[length(raw_data)])*1000
        ## each hour after that in seconds, 
        forecast_x_sequence <- seq(3600000, by = 3600000, length.out = 12)
        ## everything * 1000 to get to Javascript time
        forecast_times <- as.numeric(forecast_x_start + forecast_x_sequence)
        
        forecast_values <- as.numeric(fc$mean)
        
        hc <- highchart() %>%
            hc_chart(zoomType = "x") %>%
            hc_xAxis(type = "datetime") %>% 
            hc_add_series(
                type = "line",
                name = "data",
                data = list_parse2(data.frame(date = raw_x_date, 
                                              value = raw_data))) %>%
            hc_add_series(
                type = "arearange", 
                name = "80%",
                fillOpacity = 0.3,
                data = list_parse2(
                    data.frame(date = forecast_times,
                               upper = as.numeric(fc$upper[,1]),
                               lower = as.numeric(fc$lower[,1])))) %>%
            hc_add_series(
                type = "arearange", 
                name = "95%",
                fillOpacity = 0.3,
                data = list_parse2(
                    data.frame(date = forecast_times,
                               upper = as.numeric(fc$upper[,2]),
                               lower = as.numeric(fc$lower[,2])))) %>% 
            hc_add_series(
                type = "line",
                name = "forecast",
                data = list_parse2(
                    data.frame(date = forecast_times, 
                               value = forecast_values)))
        hc
        
    })
    
    referrals <- reactive({
        req(input$dates)
        
        bq_daterange(refs, input$dates[1], input$dates[2]) %>%
            group_by(referrer, page) %>% 
            summarise(visit_sum = sum(visits)) %>% 
            arrange(desc(visit_sum))
    })
    
    output$referral_table <- DT::renderDataTable({
        tryCatch(referrals(), error = function(e) data.frame())
    })
    
    pageviews <- reactive({
      req(input$dates)
      
      bq_daterange(pvs, input$dates[1], input$dates[2]) %>%
        mutate(path = gsub("^https://code.markedmondson.me","",page)) %>% 
        group_by(path) %>% 
        count(name = "pageviews") %>% 
        arrange(desc(pageviews))
        
    })
    
    output$pvs_chart <- renderHighchart({
      req(pageviews())
      
      pageviews() %>% hchart("column", hcaes(x=path, y = pageviews))
      
    })
    
    
    
}

# Run the application 
shinyApp(ui = ui, server = server)
