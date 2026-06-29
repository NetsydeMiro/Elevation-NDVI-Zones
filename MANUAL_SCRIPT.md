# Manual for the Elevation + NDVI Zoning Script

This document explains what the script [`R/hrdem_ndvi_zones.R`](R/hrdem_ndvi_zones.R) does and why. 

## What is this program for?

Imagine you have a farm field and you want to split it into a handful of sub-areas — "zones" — so you can treat each one differently: more seed here, less fertilizer there, better drainage over there. To draw useful zone boundaries, you need to know two things about the field:

1. **Its shape** — is part of it a low-lying wet spot, a ridge, a slope? This comes from elevation data.
2. **Its plant health/vigor** — which parts of the field are growing lush and green, and which are stressed or bare? This comes from satellite imagery, measured as [NDVI](MANUAL_GLOSSARY.md#ndvi).

This script automatically fetches both kinds of data for any field you give it, crunches the numbers, and hands you back ready-to-use zone maps you can load into farm equipment or GIS software.

## What do you need to give it?

Just **one file: your field boundary** (a [shapefile](MANUAL_GLOSSARY.md#shapefile), [GeoJSON](MANUAL_GLOSSARY.md#geojson), KML, or [GPKG](MANUAL_GLOSSARY.md#gpkg) — basically, an outline of your field's edges). Everything else — the elevation data and the satellite image — is downloaded automatically from free public sources over the internet. If you don't provide a boundary file path, the program will pop up a file-picker dialog and ask you to choose one.

## How it works, step by step

### 1. Load your field boundary
The script reads your boundary file and figures out the field's name from the filename.

### 2. Download high-resolution elevation data
It contacts Natural Resources Canada's [HRDEM](MANUAL_GLOSSARY.md#hrdem) dataset (a very detailed map of ground height, with one measurement every 2 meters) through a search service called a [STAC API](MANUAL_GLOSSARY.md#stac). It asks for just the tile(s) covering your field, then trims that down to exactly your field's outline — this trimmed elevation map is called a [DTM](MANUAL_GLOSSARY.md#dtm).

### 3. Draw contour lines
Using the elevation data, the script smooths out tiny bumps and noise, then draws [contour lines](MANUAL_GLOSSARY.md#contour-line) — the same kind of lines you'd see on a topographic map — at a chosen height interval (by default every half-meter), with thicker labeled lines every full meter.

### 4. Look for a usable satellite photo
The script searches a satellite image catalog called [Sentinel-2](MANUAL_GLOSSARY.md#sentinel-2) (via a service called [Earth Search](MANUAL_GLOSSARY.md#earth-search)) for a recent picture of your field taken during a preferred time of year (by default, August) with low [cloud cover](MANUAL_GLOSSARY.md#cloud-cover) (less than 20% by default). If nothing suitable is found in that exact window, it automatically widens the search by a month at a time (up to 3 months in each direction) until it finds an image, or gives up.

### 5. Calculate plant greenness (NDVI)
If a satellite image is found, the script combines two of its color bands (near-infrared and green light) into a single number per pixel called [NDVI](MANUAL_GLOSSARY.md#ndvi) — a standard measure of how green/healthy vegetation is. It then smooths out speckle/noise using a [median filter](MANUAL_GLOSSARY.md#median-filter), lines the image up with the elevation map, and trims it to your field boundary.

> **Note for the curious:** most NDVI you'll read about elsewhere is calculated from near-infrared and *red* light. This script instead uses near-infrared and *green* light, which is a deliberate variant some practitioners prefer — just be aware the formula differs slightly from the textbook version.

### 6. Group the field into zones
For elevation, and separately for NDVI (if available), the script uses a statistical method called [k-means clustering](MANUAL_GLOSSARY.md#k-means-clustering) to automatically sort every point in the field into a chosen number of groups ("[zones](MANUAL_GLOSSARY.md#zone)") based on how similar their values are — e.g., "low ground," "mid ground," "high ground." It repeats this for several different zone counts (2, 3, 4, and 5 zones) so you can pick whichever level of detail suits your purposes. Zones are always numbered from lowest value (zone 1) to highest value (zone *k*).

### 7. Clean up small speckles (optional)
Raw zone maps can come out looking "salt-and-peppered" — tiny isolated patches surrounded by a different zone. The script can optionally apply a [majority filter](MANUAL_GLOSSARY.md#majority-filter) that smooths these out, ensuring no patch is smaller than a chosen minimum size (30 meters wide, by default). This is turned on for NDVI zones and off for elevation zones by default.

### 8. Save the results as map files
The zone boundaries and contour lines are saved as industry-standard [shapefiles](MANUAL_GLOSSARY.md#shapefile) — the most common file format for farm equipment and GIS software — ready to import elsewhere. The script also displays 2D plots of everything as it works, color-coded with the [viridis or turbo](MANUAL_GLOSSARY.md#color-palette) color scheme.

### 9. Optional: explore in 3D
After running the script, you can call a function (`show_zones_3d()`) to open an interactive map where the zones are drawn as raised, color-coded blocks — higher elevation zones appear taller — that you can pan, tilt, and rotate. This uses a mapping library called [MapLibre](MANUAL_GLOSSARY.md#maplibre) (through the R package `mapgl`).

### 10. Built-in failsafe
Satellite imagery isn't always available (clouds, no recent pass, etc.). If no acceptable Sentinel-2 image is found even after widening the search, the script doesn't fail — it simply skips all the NDVI-related steps and still gives you complete elevation-based contours and zones.

## What you get out of it

For each zone count *k* in 2–5, written to your working folder:

- An **elevation zone shapefile** (`<field>_zones_elev_2m_k<k>_smooth_wgs84.shp`)
- An **NDVI zone shapefile**, if imagery was found (`<field>_zones_ndvi_agg<factor>_k<k>_smooth_wgs84.shp`)
- A single **contour line shapefile** (`<field>_contours_2m_int0p5m_wgs84.shp`), shared across all zone counts

Every shapefile includes a `zone` field (the zone number, 1 = lowest) and an empty `Rate` field left for you to fill in later (e.g., with a seeding or fertilizer rate per zone) in your farm management software.

All outputs are saved in the [WGS84](MANUAL_GLOSSARY.md#wgs84) coordinate system, the standard "GPS coordinates" system used by most mapping and farm equipment software.

See [MANUAL_GLOSSARY.md](MANUAL_GLOSSARY.md) for a plain-language rundown of the script's key settings and definitions of every technical term used above.
