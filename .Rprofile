# Shiny auto-sources every *.R file in an R/ directory next to app.R via
# loadSupport() before app.R itself runs. R/hrdem_ndvi_zones.R has side
# effects when sourced with its defaults (network fetches, writing
# shapefiles), so that auto-load must be disabled; app.R/web_harness.R
# source it explicitly and deliberately instead. This option must be set
# before shiny::runApp() is called, which a project-level .Rprofile
# guarantees regardless of how the app is launched (Rscript, RStudio's
# "Run App", etc.).
options(shiny.autoload.r = FALSE)
