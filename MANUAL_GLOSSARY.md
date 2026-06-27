# Glossary & Key Settings

Shared reference material for [MANUAL_SCRIPT.md](MANUAL_SCRIPT.md) and [MANUAL_WEBAPP.md](MANUAL_WEBAPP.md). Click any linked term in either manual to jump here; use your browser/editor's "back" navigation to return.

## Key settings, in plain language

| Setting | What it actually controls |
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

In the script, these are variables set near the top of [`R/hrdem_ndvi_zones.R`](R/hrdem_ndvi_zones.R). In the web app, they're sliders, dropdowns, and checkboxes in the sidebar.

## Glossary

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
