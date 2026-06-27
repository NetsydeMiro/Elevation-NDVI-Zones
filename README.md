# Elevation-NDVI-Zones
This repo contains R code for generating management zones using elevation data from Natural Resource Canada and NDVI imagery from Sentinel-2 (Earth Search). All you need is a field boundary.

## Web app (Shiny)

A Shiny app ([app.R](app.R)) wraps the script below so you can upload a boundary, adjust the
zoning parameters with sliders, and view/download results in a browser, without touching the R
console. It calls the same `run_zone_pipeline()` function the script below defines (via
[R/web_harness.R](R/web_harness.R)) — no separate logic, just a UI on top. See
[MANUAL_WEBAPP.md](MANUAL_WEBAPP.md) for a full walkthrough (also viewable inside the app itself,
under the "Manual" tab).

Run locally:
```r
shiny::runApp(".")
```

Run via Docker:
```bash
docker build -t elevation-ndvi-zones .
docker run --rm -p 3838:3838 elevation-ndvi-zones
# then browse http://localhost:3838
```

# HRDEM + Sentinel-2 NDVI Zoning Tool

See [MANUAL_SCRIPT.md](MANUAL_SCRIPT.md) for a full walkthrough of the script, and
[MANUAL_GLOSSARY.md](MANUAL_GLOSSARY.md) for term definitions and a plain-language settings
reference (shared by both manuals).

This R script:
- Downloads NRCan HRDEM 2 m DTM for a field boundary (via STAC API)
- Optionally finds a Sentinel-2 L2A scene near a target month and cloud threshold
- Computes NDVI and elevation-based management zones using k-means
- Writes contour and zone shapefiles (elevation & NDVI) to the working directory
- Provides a 2.5D interactive extrusion map (MapLibre via `{mapgl}`)

NDVI is optional: if a suitable Sentinel-2 image is not found, the script still
runs elevation-only outputs.

## Requirements

- R (≥ 4.x)
- System libraries: GDAL/PROJ/GEOS (for `{terra}` and `{sf}`)
- R packages:

```r
install.packages(c(
  "terra", "curl", "jsonlite", "dplyr",
  "mapgl", "viridis", "httr", "sf"
))
```
-Files-
R/hrdem_ndvi_zones.R – main script
data/Boundary_3DayClay.geojson – example field boundary (default)
Outputs: shapefiles written to the working directory

-How to run-
Clone or download this repository.
Open R or RStudio and set the working directory to the project root:
```r
setwd("path/to/hrdem-ndvi-zones") #path to the folder the R script is in
source("R/hrdem_ndvi_zones.R")
```
Sourcing the file runs `run_zone_pipeline()` once with its default arguments (same behaviour
as before); the returned list is assigned to `res`. To rerun with different settings:
```r
res <- run_zone_pipeline(k_range = 2:4, palette_mode = "viridis")
```
By default, the script will-
Use data/Boundary_3DayClay.geojson if it exists.
Otherwise, prompt you with file.choose() to pick a boundary file.

To change the default boundary, edit:
```r
choose_boundary <- function(path = "data/Boundary_3DayClay.geojson") { ... }
```
-Key settings-
All the knobs & dials are at the top of R/hrdem_ndvi_zones.R:
```r
palette_mode           <- "turbo"  # or "viridis"

k_range                <- 2:5

ndvi_median_size       <- 3L       # NDVI smoothing, must be odd
ndvi_agg_fact          <- 2L       # NDVI aggregation factor

apply_majority_filter_elev <- FALSE
apply_majority_filter_ndvi <- TRUE
min_mapping_unit_m         <- 30

s2_cloud_max          <- 20        # max % cloud cover
s2_months             <- c(8)      # preferred months (e.g. August)
s2_year               <- NULL      # NULL = current year
s2_max_month_offset   <- 3L        # search up to ±3 months
```
-Colour logic-
Elevation zones: zone 1 = lowest, zone k = highest
"viridis": dark purple → yellow
"turbo": cool → red

NDVI zones: zone 1 = lowest NDVI, zone k = highest NDVI
"viridis": yellow → dark purple
"turbo": red → cool

-Outputs-
The script writes (for each k in k_range) as shapefiles (WGS84):
*Elevation-based zones
*NDVI zones (if NDVI available) 
*Elevation contour lines
 
Each shapefile includes a zone field and an empty Rate field.

-3D viewing-
After sourcing the script (which assigns the result to `res`):
```r
# 3D elevation zones, k = 4
res$show_zones_3d()

# 3D elevation zones, k = 3
res$show_zones_3d(source = "elev", k = 3)

# 3D NDVI zones (if NDVI available), k = 3
res$show_zones_3d(source = "ndvi", k = 2, exaggeration = 50)
```
Each call returns the MapLibre htmlwidget; print it (or just call it at the console) to view it
in your R graphics viewer.
