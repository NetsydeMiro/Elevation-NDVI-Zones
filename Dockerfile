FROM rocker/geospatial:4.4.2

# Headless-safe bitmap graphics device for png() calls (no X11 server in the container).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcairo2-dev libxt-dev \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'options(bitmapType="cairo")' >> /usr/local/lib/R/etc/Rprofile.site

# rocker/geospatial already provides terra/sf/dplyr built against matching
# GDAL/GEOS/PROJ; only the Shiny-specific packages need installing here.
RUN R -e "install.packages(c('shiny','bslib','mapgl','viridis','curl','jsonlite','httr','zip'), repos='https://cloud.r-project.org')"

WORKDIR /srv/app
COPY .Rprofile ./.Rprofile
COPY R/ ./R/
COPY app.R ./app.R
COPY data/ ./data/

EXPOSE 3838

# shiny.autoload.r=FALSE is also set in .Rprofile; repeated here so the app
# still starts correctly even if .Rprofile is ever skipped (e.g. --vanilla).
CMD ["R", "-e", "options(shiny.autoload.r = FALSE); shiny::runApp('/srv/app', host='0.0.0.0', port=3838)"]
