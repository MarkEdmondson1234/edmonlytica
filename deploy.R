library(googleCloudRunner)

# a repo with the Dockerfile template
repo <- cr_buildtrigger_repo("MarkEdmondson1234/edmonlytica")

# deploy a cloud build trigger so each commit build the image
cr_deploy_docker_trigger(
  repo,
  image = "shiny-edmonlytica"
)

# deploy to Cloud Run
cr_run(sprintf("gcr.io/%s/shiny-edmonlytica:latest",cr_project_get()),
       name = "shiny-edmonlytica",
       concurrency = 80,
       max_instances = 1,
       env_vars = paste0("BQ_DEFAULT_PROJECT_ID=", Sys.getenv("BQ_DEFAULT_PROJECT_ID")))