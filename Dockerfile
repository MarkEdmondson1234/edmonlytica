FROM rocker/shiny-verse

RUN apt-get install gcc-7 g++-7 gfortran-7

RUN install2.r -e \
  bigQueryR highcharter xts forecast shinythemes DT
  
COPY app/ /srv/shiny-server/

COPY shiny-customized.config /etc/shiny-server/shiny-server.conf

EXPOSE 8080

USER shiny

# avoid s6 initialization
# see https://github.com/rocker-org/shiny/issues/79
CMD ["/usr/bin/shiny-server"]