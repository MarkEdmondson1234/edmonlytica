FROM rocker/shiny-verse

RUN apt-get update && apt-get install -y \
  build-essential \
  libglpk40 # https://github.com/malcolmbarrett/ggdag/issues/47

RUN install2.r -e \
  bigQueryR highcharter xts forecast shinythemes DT
  
COPY app/ /srv/shiny-server/

COPY shiny-customized.config /etc/shiny-server/shiny-server.conf

EXPOSE 8080

USER shiny

# avoid s6 initialization
# see https://github.com/rocker-org/shiny/issues/79
CMD ["/usr/bin/shiny-server"]