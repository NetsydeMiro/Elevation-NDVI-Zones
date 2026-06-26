# Manual for the Elevation + NDVI Zoning Tool

This document explains what the script [`R/hrdem_ndvi_zones.R`](R/hrdem_ndvi_zones.R) does and why. If you just want to install and run it, see [README.md](README.md). 

## What is this program for?

Imagine you have a farm field and you want to split it into a handful of sub-areas — "zones" — so you can treat each one differently: more seed here, less fertilizer there, better drainage over there. To draw useful zone boundaries, you need to know two things about the field:

1. **Its shape** — is part of it a low-lying wet spot, a ridge, a slope? This comes from elevation data.
2. **Its plant health/vigor** — which parts of the field are growing lush and green, and which are stressed or bare? This comes from satellite imagery, measured as [NDVI](#ndvi).

This script automatically fetches both kinds of data for any field you give it, crunches the numbers, and hands you back ready-to-use zone maps you can load into farm equipment or GIS software.

## What do you need to give it?

Just **one file: your field boundary** (a [shapefile](#shapefile), [GeoJSON](#geojson), KML, or [GPKG](#gpkg) — basically, an outline of your field's edges). Everything else — the elevation data and the satellite image — is downloaded automatically from free public sources over the internet. If you don't provide a boundary file path, the program will pop up a file-picker dialog and ask you to choose one.

## How it works, step by step

### 1. Load your field boundary
The script reads your boundary file and figures out the field's name from the filename.

### 2. Download high-resolution elevation data
It contacts Natural Resources Canada's [HRDEM](#hrdem) dataset (a very detailed map of ground height, with one measurement every 2 meters) through a search service called a [STAC API](#stac). It asks for just the tile(s) covering your field, then trims that down to exactly your field's outline — this trimmed elevation map is called a [DTM](#dtm).

### 3. Draw contour lines
Using the elevation data, the script smooths out tiny bumps and noise, then draws [contour lines](#contour-line) — the same kind of lines you'd see on a topographic map — at a chosen height interval (by default every half-meter), with thicker labeled lines every full meter.

### 4. Look for a usable satellite photo
The script searches a satellite image catalog called [Sentinel-2](#sentinel-2) (via a service called [Earth Search](#earth-search)) for a recent picture of your field taken during a preferred time of year (by default, August) with low [cloud cover](#cloud-cover) (less than 20% by default). If nothing suitable is found in that exact window, it automatically widens the search by a month at a time (up to 3 months in each direction) until it finds an image, or gives up.

### 5. Calculate plant greenness (NDVI)
If a satellite image is found, the script combines two of its color bands (near-infrared and green light) into a single number per pixel called [NDVI](#ndvi) — a standard measure of how green/healthy vegetation is. It then smooths out speckle/noise using a [median filter](#median-filter), lines the image up with the elevation map, and trims it to your field boundary.

> **Note for the curious:** most NDVI you'll read about elsewhere is calculated from near-infrared and *red* light. This script instead uses near-infrared and *green* light, which is a deliberate variant some practitioners prefer — just be aware the formula differs slightly from the textbook version.

### 6. Group the field into zones
For elevation, and separately for NDVI (if available), the script uses a statistical method called [k-means clustering](#k-means-clustering) to automatically sort every point in the field into a chosen number of groups ("[zones](#zone)") based on how similar their values are — e.g., "low ground," "mid ground," "high ground." It repeats this for several different zone counts (2, 3, 4, and 5 zones) so you can pick whichever level of detail suits your purposes. Zones are always numbered from lowest value (zone 1) to highest value (zone *k*).

### 7. Clean up small speckles (optional)
Raw zone maps can come out looking "salt-and-peppered" — tiny isolated patches surrounded by a different zone. The script can optionally apply a [majority filter](#majority-filter) that smooths these out, ensuring no patch is smaller than a chosen minimum size (30 meters wide, by default). This is turned on for NDVI zones and off for elevation zones by default.

### 8. Save the results as map files
The zone boundaries and contour lines are saved as industry-standard [shapefiles](#shapefile) — the most common file format for farm equipment and GIS software — ready to import elsewhere. The script also displays 2D plots of everything as it works, color-coded with the [viridis or turbo](#color-palette) color scheme.

### 9. Optional: explore in 3D
After running the script, you can call a function (`show_zones_3d()`) to open an interactive map where the zones are drawn as raised, color-coded blocks — higher elevation zones appear taller — that you can pan, tilt, and rotate. This uses a mapping library called [MapLibre](#maplibre) (through the R package `mapgl`).

### 10. Built-in failsafe
Satellite imagery isn't always available (clouds, no recent pass, etc.). If no acceptable Sentinel-2 image is found even after widening the search, the script doesn't fail — it simply skips all the NDVI-related steps and still gives you complete elevation-based contours and zones.

## What you get out of it

For each zone count *k* in 2–5, written to your working folder:

- An **elevation zone shapefile** (`<field>_zones_elev_2m_k<k>_smooth_wgs84.shp`)
- An **NDVI zone shapefile**, if imagery was found (`<field>_zones_ndvi_agg<factor>_k<k>_smooth_wgs84.shp`)
- A single **contour line shapefile** (`<field>_contours_2m_int0p5m_wgs84.shp`), shared across all zone counts

Every shapefile includes a `zone` field (the zone number, 1 = lowest) and an empty `Rate` field left for you to fill in later (e.g., with a seeding or fertilizer rate per zone) in your farm management software.

All outputs are saved in the [WGS84](#wgs84) coordinate system, the standard "GPS coordinates" system used by most mapping and farm equipment software.

## Key settings, in plain language

| Setting in the script | What it actually controls |
|---|---|
| `palette_mode` | Which [color scheme](#color-palette) is used for the plots — `"turbo"` (cool-to-red) or `"viridis"` (purple-to-yellow) |
| `k_range` | How many different zone counts to generate (default: 2 through 5) |
| `contour_interval` | Vertical spacing between [contour lines](#contour-line), in meters |
| `ndvi_median_size` | How aggressively to smooth out noise/speckle in the satellite greenness data |
| `ndvi_agg_fact` | How much to "zoom out" (lower resolution) the greenness data before grouping it into zones, to avoid overly jagged zone shapes |
| `apply_majority_filter_elev` / `apply_majority_filter_ndvi` | Whether to clean up small speckled patches in elevation / NDVI zones |
| `min_mapping_unit_m` | The smallest patch width (in meters) allowed to survive the speckle cleanup |
| `s2_cloud_max` | Maximum acceptable cloud cover percentage for a satellite image |
| `s2_months` / `s2_year` | Preferred month(s) and year to search for a satellite image |
| `s2_max_month_offset` | How many months earlier/later than preferred the search is allowed to expand if no image is found |

## Glossary

Click any linked term in the text above to jump here; click a term below to jump back up isn't needed — just scroll back up, or use your browser/editor's "back" navigation.

### Bounding Box
Also called a **bbox**. A simple rectangle — defined by its westmost, southmost, eastmost, and northmost edges — used to describe roughly where a field is, so a data source knows what area to search or return.

### Cloud Cover
The percentage of a satellite image that is obscured by clouds. Cloudy images are unusable for measuring plant health, so the script filters them out.

### Color Palette
A standardized set of colors used to represent a range of values on a map, chosen so the colors are easy to read consistently (e.g., always dark-to-light or cool-to-warm). "Viridis" and "turbo" — the two options this script supports — are popular, scientifically-designed color schemes.

### Contour Line
A line on a map connecting all points at the same elevation — the same concept used on topographic hiking maps, just generated automatically here from the elevation data.

### CRS
Short for **Coordinate Reference System** — a defined way of describing locations on Earth's curved surface using numbers (coordinates), so that different maps and data sets can be lined up correctly with one another.

### DTM
Short for **Digital Terrain Model** — a grid of elevation measurements representing the bare ground surface (with trees, buildings, and crops removed), used here as the elevation map of your field.

### Earth Search
A free, public web service that lets the script search through Sentinel-2 satellite images by location, date, and cloud cover, without needing an account or API key.

### GeoJSON
A common text-based file format for storing map shapes (like a field boundary), readable by most GIS and farm software.

### GPKG
Short for **GeoPackage** — another common file format for storing map data, similar in purpose to a shapefile but stored as a single file.

### HRDEM
Short for **High Resolution Digital Elevation Model** — a very detailed, government-produced elevation dataset for Canada, with a ground resolution of 2 meters, meaning it captures elevation roughly every 2 meters across the landscape. Produced by NRCan.

### K-means Clustering
A statistical technique that automatically sorts a set of numeric values into a chosen number of groups ("clusters") so that values within a group are as similar as possible, and values in different groups are as different as possible. Here it's used to turn a continuous map of elevation or greenness values into a small number of discrete zones.

### Majority Filter
Also called enforcing a **minimum mapping unit**. A cleanup step that looks at small isolated "speckle" patches in a zone map and reassigns them to match their surrounding neighborhood, ensuring no patch is smaller than a chosen minimum size.

### MapLibre
An open-source interactive mapping library (used here via the R package `mapgl`) that powers the optional 3D-style zone viewer.

### Median Filter
A noise-reduction/smoothing technique that replaces each value with the "middle" (median) value of its immediate neighbors, which removes random speckle/noise from data without blurring real edges as much as averaging would.

### NDVI
Short for **Normalized Difference Vegetation Index** — a number, typically between -1 and 1, calculated from satellite imagery that indicates how lush and healthy vegetation is at a given spot. Higher values generally mean denser, healthier plant growth. (This script computes it from near-infrared and green light, a variant of the more common near-infrared/red formula.)

### NRCan
Short for **Natural Resources Canada** — the Canadian federal government department that produces and publishes the HRDEM elevation dataset used by this script.

### Sentinel-2
A pair of European Space Agency satellites that repeatedly photograph the Earth's surface in multiple light wavelengths (including near-infrared, useful for measuring vegetation). "L2A" refers to a particular processing level of this imagery that has already been corrected for atmospheric effects, making it ready for analysis.

### Shapefile
A widely-used file format (actually a small group of files sharing a name, with extensions like `.shp`, `.dbf`, `.shx`, `.prj`) for storing map shapes — points, lines, or areas — along with associated data, readable by virtually all GIS and precision-agriculture software.

### STAC
Short for **SpatioTemporal Asset Catalog** — a standardized way for online services to let you search through and find geographic datasets (like elevation tiles or satellite images) by location and date, similar to searching a library catalog.

### WGS84
The standard global coordinate system used by GPS and most mapping software (also known by its technical code, EPSG:4326). All the script's output shapefiles are saved in this system so they're compatible with the widest range of other software.

### Zone
A sub-area of the field that has been grouped together because its elevation (or NDVI) values are similar to each other and different from neighboring zones — the actual output you'd use to vary treatment across the field.
