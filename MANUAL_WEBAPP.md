# Manual for the Elevation + NDVI Zoning Web App

This document explains how to use the Shiny web app ([`app.R`](app.R)) — the browser-based, no-code version of the zoning tool. It drives the same pipeline as [`R/hrdem_ndvi_zones.R`](R/hrdem_ndvi_zones.R) under the hood; if you'd rather work from the R console, see [MANUAL_SCRIPT.md](MANUAL_SCRIPT.md) instead. For term definitions and a plain-language settings reference, see [MANUAL_GLOSSARY.md](MANUAL_GLOSSARY.md).

## What is this program for?

Imagine you have a farm field and you want to split it into a handful of sub-areas — "zones" — so you can treat each one differently: more seed here, less fertilizer there, better drainage over there. To draw useful zone boundaries, you need to know two things about the field:

1. **Its shape** — is part of it a low-lying wet spot, a ridge, a slope? This comes from elevation data.
2. **Its plant health/vigor** — which parts of the field are growing lush and green, and which are stressed or bare? This comes from satellite imagery, measured as [NDVI](MANUAL_GLOSSARY.md#ndvi).

This web app is a point-and-click interface to the same engine: upload your field boundary, adjust a handful of settings with sliders and checkboxes, click "Run analysis," and download ready-to-use zone maps — all in a browser, with no R installation or coding required.

## What do you need to give it?

Just **one field boundary**, uploaded via the "Field boundary" file picker in the sidebar. You can upload:

- A single [GeoJSON](MANUAL_GLOSSARY.md#geojson) or GPKG/KML file, or
- A full [shapefile](MANUAL_GLOSSARY.md#shapefile) set — select all of `.shp`, `.shx`, `.dbf`, `.prj` (and `.cpg` if present) together in the file picker.

If you don't already have a boundary file, the helper text under the upload box links to [geojson.io](https://geojson.io), where you can draw one and export it as GeoJSON. Everything else — the elevation data and the satellite image — is downloaded automatically from free public sources once you click "Run analysis."

## How it works, step by step

### 1. Upload your field boundary
Use the "Field boundary" file picker at the top of the sidebar.

### 2. Adjust the settings (optional)
The sidebar groups all the tunable dials into collapsible sections. Sensible defaults are pre-filled, so you can skip straight to step 3 if you just want a first look — open any section to fine-tune it:

- **Palette** — choose the color scheme used in the plots, Turbo (cool-to-red) or Viridis (purple-to-yellow). See [Color Palette](MANUAL_GLOSSARY.md#color-palette).
- **Zones** — a slider for how many zone counts to generate (e.g. 2 through 5 zones).
- **NDVI processing** — the smoothing window size and aggregation factor used when calculating [NDVI](MANUAL_GLOSSARY.md#ndvi).
- **Majority filter (minimum mapping unit)** — checkboxes to clean up small speckled patches in elevation and/or NDVI zone maps, plus the minimum patch width to enforce. See [Majority Filter](MANUAL_GLOSSARY.md#majority-filter).
- **Sentinel-2 search** — maximum cloud cover, preferred month(s) and year, and how far the search window can widen if no clean image is found nearby. See [Sentinel-2](MANUAL_GLOSSARY.md#sentinel-2) and [Cloud Cover](MANUAL_GLOSSARY.md#cloud-cover).
- **Contours & smoothing** — the vertical spacing between [contour lines](MANUAL_GLOSSARY.md#contour-line) and how much to smooth the elevation/NDVI zone boundaries.

### 3. Click "Run analysis"
A progress indicator shows while the app fetches your field's elevation and satellite data and computes zones. A status message appears below the button when the run finishes, noting whether a usable Sentinel-2 scene was found for NDVI.

### 4. Review the results in the tabs
- **Elevation** — the elevation plot and contour-line plot for your field.
- **NDVI** — the combined elevation/NDVI panel, if a usable satellite scene was found; otherwise a note explaining that NDVI was skipped.
- **Zone maps** — grids showing the elevation zones (and NDVI zones, if available) at every generated zone count.
- **3D view** — pick a zone source (Elevation, or NDVI if available), a zone count *k*, and a height exaggeration factor, then click "Render 3D view" for an interactive [MapLibre](MANUAL_GLOSSARY.md#maplibre) map — higher zones appear taller. Navigation: drag to pan, scroll or pinch to zoom, right-click drag (or Ctrl+drag) to rotate and tilt the view, and "2 fingers + drag" to rotate/tilt on touchscreens.
- **Downloads** — shows the detected field name and a "Download all shapefiles (.zip)" button.
- **Manual** — this document, rendered for reference without leaving the app.

### 5. Built-in failsafe
Satellite imagery isn't always available (clouds, no recent pass, etc.). If no acceptable Sentinel-2 image is found even after widening the search, the run doesn't fail — the NDVI tab and NDVI zone plots simply note that they were skipped, and you still get complete elevation-based contours and zones.

## What you get out of it

Click "Download all shapefiles (.zip)" on the **Downloads** tab to get a single zip containing, for each zone count *k* you generated:

- An **elevation zone shapefile**
- An **NDVI zone shapefile**, if imagery was found
- A single **contour line shapefile**, shared across all zone counts

Every shapefile includes a `zone` field (the zone number, 1 = lowest) and an empty `Rate` field left for you to fill in later (e.g., with a seeding or fertilizer rate per zone) in your farm management software. All outputs are saved in the [WGS84](MANUAL_GLOSSARY.md#wgs84) coordinate system, the standard "GPS coordinates" system used by most mapping and farm equipment software.

See [MANUAL_GLOSSARY.md](MANUAL_GLOSSARY.md) for a plain-language rundown of every setting and a glossary of the technical terms used above.
