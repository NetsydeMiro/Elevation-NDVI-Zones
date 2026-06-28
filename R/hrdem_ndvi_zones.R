# ============================================================
# HRDEM 2 m + Sentinel-2 NDVI Zone Mapping
#
# - Downloads HRDEM 2 m DTM via STAC
# - Optionally downloads Sentinel-2 L2A via Earth Search (no API key)
# - Computes NDVI, elevation & NDVI k-means zones
# - Writes contour + zone shapefiles
# - Provides 2.5D map via mapgl / MapLibre
#
# Key knobs:
#   palette_mode          "viridis" or "turbo"
#   k_range (number of zones)  vector of k (e.g., 2:5)
#   ndvi_median_size      NDVI smoothing window (odd integer)
#   ndvi_agg_fact         NDVI aggregation factor for zoning
#   min_mapping_unit_m    min patch width for majority filter
#   s2_months, s2_year,
#   s2_max_month_offset   Sentinel-2 search behaviour
#
# NDVI is optional: if no acceptable Sentinel-2 image is found,
# elevation products still run; NDVI and NDVI zones are skipped.
#
# All of the above knobs, plus the field boundary path and the output/plot
# directories, are now arguments to run_zone_pipeline() below (rather than
# top-level script variables) so the pipeline can be called programmatically
# (e.g. from a Shiny web harness) without editing this file. Calling this
# file via source() still runs the pipeline once with its original defaults,
# unless options(hrdem_ndvi_zones.skip_autorun = TRUE) has been set beforehand.
# ============================================================

library(terra)
library(curl)
library(jsonlite)
library(dplyr)
library(mapgl)
library(viridis)
library(httr)

`%||%` <- function(a, b) if (!is.null(a)) a else b

choose_boundary <- function(path = "data/Boundary_3DayClay.geojson") {
  if (!is.null(path) && file.exists(path)) {
    path
  } else {
    message("Default boundary not found; using file chooser.")
    file.choose()
  }
}

run_zone_pipeline <- function(
  boundary_path              = NULL,   # NULL -> choose_boundary() default/file.choose()
  palette_mode               = "turbo", # "turbo" or "viridis"
  k_range                    = 2:5,
  ndvi_median_size           = 3L,      # must be odd
  ndvi_agg_fact              = 2L,
  apply_majority_filter_elev = FALSE,
  apply_majority_filter_ndvi = TRUE,
  min_mapping_unit_m         = 30,
  s2_cloud_max               = 20,
  s2_months                  = c(8),
  s2_year                    = NULL,
  s2_max_month_offset        = 3L,
  contour_interval           = 0.5,
  smooth_dist_elev           = 3,
  smooth_dist_ndvi           = 0,
  out_dir                    = getwd(),
  plot_dir                   = NULL,    # if set, plot blocks are saved as PNGs here instead of drawn live
  progress_cb                = NULL     # optional function(detail, amount) for UI progress reporting
) {

set.seed(1234)  # reproducible k-means / zones

# Mirrors message() to an optional progress callback (e.g. Shiny's
# incProgress()) so step-by-step console detail also drives a progress bar.
report <- function(detail, amount = 0) {
  message(detail)
  if (!is.null(progress_cb)) progress_cb(detail, amount)
}

# -------------------- USER INPUTS --------------------
if (is.null(boundary_path)) {
  boundary_path <- choose_boundary()   # SHP/GeoJSON/KML/GPKG
}
use_user_raster   <- FALSE
user_raster_path  <- if (use_user_raster) file.choose() else NULL

hrdem_stac_url    <- "https://datacube.services.geo.ca/stac/api/search"

# Sentinel-2 (Earth Search) parameters
s2_search_url        <- "https://earth-search.aws.element84.com/v1/search"
s2_collection        <- "sentinel-2-l2a"

# k-means elevation / NDVI zones

target_crs <- "EPSG:4326"        # WGS84 for vector outputs / web maps

# -------------------- COLOR PALETTES (DETERMINISTIC) --------------------
if (palette_mode == "viridis") {
  # Elevation: zone 1 = lowest (dark purple), zone k = highest (yellow)
  pal_elev_fun <- function(n) {
    colorRampPalette(
      c("#440154", "#31688E", "#35B779", "#FDE725")
    )(n)
  }
  # NDVI: lowest = yellow, highest = dark purple
  pal_ndvi_fun <- function(n) rev(pal_elev_fun(n))

} else if (palette_mode == "turbo") {
  # Elevation: zone 1 = lowest (cool), zone k = highest (red end)
  pal_elev_fun <- function(n) viridis::viridis(n, option = "turbo")
  # NDVI: lowest NDVI = red end, highest NDVI = cool end
  pal_ndvi_fun <- function(n) rev(viridis::viridis(n, option = "turbo"))

} else {
  stop("Unknown palette_mode: use 'viridis' or 'turbo'")
}

pal_elev_cont <- pal_elev_fun(40)
pal_nd        <- pal_ndvi_fun(40)

# -------------------- BOUNDARY + NAMING --------------------
boundary   <- vect(boundary_path)
orig_crs   <- crs(boundary, proj = TRUE)
file_name  <- basename(boundary_path)
field_name <- sub("_.*$", "", tools::file_path_sans_ext(file_name))

report(paste0("Boundary CRS: ", orig_crs), 0.02)
report(paste0("Field name: ", field_name), 0.02)

# -------------------- HRDEM 2 m DTM (NO DTM REPROJECTION) --------------------
fetch_hrdem_2m <- function(boundary, stac_url) {
  boundary_ll <- project(boundary, "EPSG:4326")
  e           <- ext(boundary_ll)
  bbox        <- c(xmin(e), ymin(e), xmax(e), ymax(e))
  bbox        <- unname(bbox)

  payload <- jsonlite::toJSON(
    list(
      collections = list("hrdem-mosaic-2m"),
      bbox        = bbox,
      limit       = 1
    ),
    auto_unbox = TRUE
  )

  h <- curl::new_handle()
  curl::handle_setheaders(h, "Content-Type" = "application/json")
  curl::handle_setopt(h, postfields = payload)

  res <- curl::curl_fetch_memory(stac_url, handle = h)
  if (res$status_code < 200 || res$status_code >= 300) {
    stop("HRDEM STAC request failed with status: ", res$status_code)
  }

  items <- jsonlite::fromJSON(rawToChar(res$content), simplifyVector = FALSE)
  if (length(items$features) == 0) {
    stop("No HRDEM 2 m features returned from STAC for this bbox.")
  }

  assets <- items$features[[1]]$assets
  href   <- (assets[["Digital Terrain Model (VRT)"]]$href) %||%
    (assets[["Digital Terrain Model (COG)"]]$href) %||%
    (assets$dtm$href)

  if (is.null(href) || !nzchar(href)) {
    stop("No DTM asset found in HRDEM 2 m STAC response.")
  }

  report(paste0("Using HRDEM 2 m asset: ", href), 0.03)
  rast(paste0("/vsicurl/", href))
}

if (use_user_raster) {
  dtm <- rast(user_raster_path)
  report(paste0("Using user raster: ", user_raster_path), 0.05)
} else {
  dtm <- fetch_hrdem_2m(boundary, hrdem_stac_url)
  report("Loaded HRDEM 2 m DTM via STAC.", 0.10)
}

if (is.na(crs(dtm))) stop("DTM has no CRS.")
dtm_crs <- crs(dtm, proj = TRUE)
report(paste0("DTM CRS (2 m): ", dtm_crs), 0.02)

# -------------------- CROP TO FIELD (2 m) --------------------
boundary_dtm <- project(boundary, dtm_crs)

dtm_field_2m <- dtm |>
  crop(boundary_dtm) |>
  mask(boundary_dtm)

if (all(is.na(values(dtm_field_2m)))) {
  stop("DTM subset for field is all NA. Check CRS/extent alignment.")
}

report(
  paste0("dtm_field_2m resolution: ", paste(res(dtm_field_2m), collapse = ", ")),
  0.02
)

if (!is.null(plot_dir)) png(file.path(plot_dir, "plot_elevation.png"), width = 900, height = 700, res = 120)
par(mfrow = c(1, 1), mar = c(3, 3, 3, 4))
plot(dtm_field_2m,
     main   = "Elevation (2 m grid)",
     col    = pal_elev_cont,
     legend = TRUE,
     axes   = FALSE)
lines(boundary_dtm)
if (!is.null(plot_dir)) dev.off()

# -------------------- STYLIZED CONTOUR MAP --------------------
stopifnot(inherits(dtm_field_2m, "SpatRaster"))
dtm_clip <- dtm_field_2m

interval_m     <- contour_interval
highlight_step <- 1.0               # bold/label every 1 m
agg_factor     <- 3                 # effective coarser grid
smooth_size    <- 5                 # odd kernel
smooth_passes  <- 2
label_cex_hi   <- 0.8

r <- if (agg_factor > 1) {
  terra::aggregate(dtm_clip, fact = agg_factor, fun = mean, na.rm = TRUE)
} else {
  dtm_clip
}

stopifnot(smooth_size %% 2 == 1)
k_mat <- matrix(1 / (smooth_size^2), nrow = smooth_size, ncol = smooth_size)
for (i in seq_len(smooth_passes)) {
  r <- terra::focal(
    r,
    w        = k_mat,
    fun      = mean,
    na.rm    = TRUE,
    pad      = TRUE,
    padValue = NA
  )
}

# re-crop/mask smoothed raster to field so contours respect boundary
r <- mask(crop(r, boundary_dtm), boundary_dtm)

rr   <- terra::global(r, fun = range, na.rm = TRUE)
vmin <- rr[1, 1]
vmax <- rr[1, 2]
if (!is.finite(vmin) || !is.finite(vmax)) stop("Raster has no finite values.")
if (vmin >= vmax) {
  vmin <- vmin - interval_m
  vmax <- vmax + interval_m
}

lo   <- floor(vmin / interval_m) * interval_m
hi   <- ceiling(vmax / interval_m) * interval_m
levs <- seq(lo, hi, by = interval_m)

contours_sty <- terra::as.contour(r, levels = levs)

# ensure CRS match for clipping
boundary_for_contours <- project(boundary_dtm, crs(contours_sty))
contours_sty <- terra::crop(contours_sty, boundary_for_contours)
contours_sty <- terra::mask(contours_sty, boundary_for_contours)

tol <- max(1e-9, interval_m / 20)
is_highlight <- abs((contours_sty$level / highlight_step) -
                      round(contours_sty$level / highlight_step)) < tol

label_contours_int <- function(contours_sty, is_highlight, label_cex_hi = 0.8) {
  if (!any(is_highlight)) return(invisible(NULL))

  cont_hi <- contours_sty[is_highlight, ]
  lines(cont_hi, col = "black", lwd = 1.2)

  cont_hi_diss <- terra::aggregate(cont_hi, by = "level")

  # spatSample() does not support sampling along lines, so pick the
  # middle vertex of each level's contour as its label point instead.
  verts_hi <- terra::as.points(cont_hi_diss)
  levels_hi <- sort(unique(verts_hi$level))
  mid_idx <- vapply(levels_hi, function(lv) {
    idx <- which(verts_hi$level == lv)
    idx[ceiling(length(idx) / 2)]
  }, integer(1))
  lab_pts_hi <- verts_hi[mid_idx, ]

  if (nrow(lab_pts_hi) > 0) {
    lab_txt_hi <- as.character(round(lab_pts_hi$level))
    xy_hi      <- terra::crds(lab_pts_hi)
    text(xy_hi[, 1], xy_hi[, 2],
         labels = lab_txt_hi,
         cex    = label_cex_hi,
         col    = "black",
         font   = 2,
         pos    = 3)
  }
}

if (!is.null(plot_dir)) png(file.path(plot_dir, "plot_contours.png"), width = 900, height = 700, res = 120)
par(mfrow = c(1, 1), mar = c(3, 3, 3, 4))
plot(
  r,
  main   = sprintf("Contours (%.2f m)", interval_m),
  col    = pal_elev_cont,
  legend = TRUE,
  axes   = FALSE
)
lines(contours_sty, col = "gray70", lwd = 0.6)
label_contours_int(contours_sty, is_highlight, label_cex_hi)
lines(boundary_dtm, col = "black", lwd = 1.5)
if (!is.null(plot_dir)) dev.off()

contours_vec_dtm <- contours_sty

# ========== Sentinel-2 L2A via Earth Search (httr) =============================

get_asset_href <- function(assets, patterns) {
  if (is.null(assets) || length(assets) == 0) return(NULL)
  asset_names <- names(assets)
  if (is.null(asset_names)) return(NULL)

  for (pat in patterns) {
    hits <- asset_names[grepl(pat, asset_names, ignore.case = TRUE)]
    if (length(hits) > 0) {
      key  <- hits[1]
      href <- assets[[key]]$href %||% assets[[key]]$url
      if (!is.null(href) && nzchar(href)) return(href)
    }
  }
  NULL
}

fetch_latest_s2_aug <- function(boundary,
                                search_url       = s2_search_url,
                                collection       = s2_collection,
                                cloud_max        = s2_cloud_max,
                                months           = s2_months,
                                year             = s2_year,
                                max_month_offset = s2_max_month_offset) {
  stopifnot(inherits(boundary, "SpatVector"))

  current_year <- as.integer(format(Sys.Date(), "%Y"))
  year_for_s2  <- if (!is.null(year)) year else current_year

  min_m0 <- min(months)
  max_m0 <- max(months)

  # "target" mid date (used for choosing the closest scene)
  target_mid <- as.Date(sprintf("%04d-%02d-15", year_for_s2, round(mean(months))))

  # boundary bbox in WGS84
  boundary_ll <- project(boundary, "EPSG:4326")
  e           <- ext(boundary_ll)
  bbox        <- c(xmin(e), ymin(e), xmax(e), ymax(e))
  bbox        <- as.numeric(bbox)

  feat <- NULL

  # Expand month window from offset = 0 out to max_month_offset
  for (offset in 0:max_month_offset) {
    min_m <- max(1L, min_m0 - offset)
    max_m <- min(12L, max_m0 + offset)

    start_date      <- as.Date(sprintf("%04d-%02d-01", year_for_s2, min_m))
    end_month_start <- as.Date(sprintf("%04d-%02d-01", year_for_s2, max_m))
    end_date        <- seq(end_month_start, by = "1 month", length.out = 2)[2] - 1

    report(
      paste0(
        "Searching Sentinel-2 from ", start_date, " to ", end_date,
        " (offset = ", offset, " month(s), cloud <", cloud_max, "%)"
      ),
      0.02
    )

    datetime <- paste0(
      format(start_date, "%Y-%m-%d"), "T00:00:00Z/",
      format(end_date,   "%Y-%m-%d"), "T23:59:59Z"
    )

    body_list <- list(
      collections = list(collection),
      bbox        = bbox,
      datetime    = datetime,
      limit       = 50L,
      query       = list(
        `eo:cloud_cover` = list(
          lt = cloud_max
        )
      )
    )

    res <- httr::POST(
      url    = search_url,
      body   = body_list,
      encode = "json"
    )

    if (httr::status_code(res) < 200 || httr::status_code(res) >= 300) {
      txt <- httr::content(res, "text", encoding = "UTF-8")
      stop("Sentinel-2 STAC request failed (",
           httr::status_code(res), "): ", txt)
    }

    items <- httr::content(res, as = "parsed", type = "application/json")
    if (length(items$features) == 0) {
      next
    }

    # choose scene closest in time to target_mid
    dt_strings <- vapply(
      items$features,
      function(f) f$properties$`datetime`,
      FUN.VALUE = character(1)
    )

    dt_vals          <- as.POSIXct(dt_strings, tz = "UTC")
    target_mid_posix <- as.POSIXct(target_mid, tz = "UTC")

    idx_closest <- which.min(abs(difftime(dt_vals, target_mid_posix, units = "secs")))
    feat        <- items$features[[idx_closest]]
    break
  }

  if (is.null(feat)) {
    stop("No Sentinel-2 items found within ±", max_month_offset,
         " month(s) of target months ",
         paste(months, collapse = ","), ", cloud <", cloud_max, "%.")
  }

  assets   <- feat$assets
  acq_date <- feat$properties$`datetime`
  report(paste0("Using Sentinel-2 item acquired at: ", acq_date), 0.06)
  report(
    paste0("Available asset names: ", paste(names(assets), collapse = ", ")),
    0.04
  )

  href_blue  <- get_asset_href(assets, c("^blue$", "blue"))
  href_green <- get_asset_href(assets, c("^green$", "green"))
  href_red   <- get_asset_href(assets, c("^red$", "red"))
  href_nir   <- get_asset_href(assets, c("^nir$", "nir"))

  if (any(sapply(list(href_blue, href_green, href_red, href_nir), is.null))) {
    stop(
      "Could not resolve one or more Sentinel-2 band assets (blue, green, red, nir).\n",
      "Asset names available:\n  ", paste(names(assets), collapse = ", "), "\n",
      "Adjust get_asset_href() patterns if needed."
    )
  }

  b_blue  <- rast(paste0("/vsicurl/", href_blue))
  b_green <- rast(paste0("/vsicurl/", href_green))
  b_red   <- rast(paste0("/vsicurl/", href_red))
  b_nir   <- rast(paste0("/vsicurl/", href_nir))

  s2_crs      <- crs(b_blue, proj = TRUE)
  boundary_s2 <- project(boundary, s2_crs)

  rgb_stack <- c(b_red, b_green, b_blue)
  names(rgb_stack) <- c("red", "green", "blue")

  rgb_field <- rgb_stack |>
    crop(boundary_s2) |>
    mask(boundary_s2)

  nir_field <- b_nir |>
    crop(boundary_s2) |>
    mask(boundary_s2)

  list(
    rgb_field   = rgb_field,
    nir_field   = nir_field,
    boundary_s2 = boundary_s2,
    datetime    = acq_date
  )
}

# ---------- NDVI PIPELINE WITH FAILSAFE ---------------------------------------
have_ndvi <- TRUE
s2_info <- tryCatch(
  fetch_latest_s2_aug(boundary),
  error = function(e) {
    report(paste0("Warning: Sentinel-2 fetch failed: ", conditionMessage(e)), 0.03)
    report("Continuing without NDVI; only elevation outputs will be generated.", 0.02)
    return(NULL)
  }
)

s2_datetime <- NULL

if (!is.null(s2_info)) {
  rgb_field   <- s2_info$rgb_field
  nir_field   <- s2_info$nir_field
  boundary_s2 <- s2_info$boundary_s2
  s2_datetime <- s2_info$datetime

  date_label  <- sub("T.*$", "", s2_datetime)   # YYYY-MM-DD

  # NDVI = (nir - green) / (nir + green)
  green_band <- rgb_field[[2]]
  denom      <- nir_field + green_band

  nd_ng <- (nir_field - green_band) / denom
  nd_ng[denom <= 0] <- NA
  names(nd_ng) <- "NDVI"

  # Reproject NDVI to DTM CRS, crop + mask to field
  nd_ng_dtm <- project(nd_ng, dtm_field_2m, method = "bilinear")
  nd_ng_dtm <- nd_ng_dtm |>
    crop(boundary_dtm) |>
    mask(boundary_dtm)

  # 3x3 (or ndvi_median_size^2) median smoothing
  if (ndvi_median_size %% 2 != 1) stop("ndvi_median_size must be odd.")
  w_med <- matrix(1, ndvi_median_size, ndvi_median_size)

  nd_ng_smooth <- terra::focal(
    nd_ng_dtm,
    w         = w_med,
    fun       = median,
    na.rm     = TRUE,
    na.policy = "omit",
    pad       = TRUE,
    padValue  = NA
  )

  # enforce field boundary after smoothing
  nd_ng_smooth <- nd_ng_smooth |>
    crop(boundary_dtm) |>
    mask(boundary_dtm)

  # Aggregate NDVI to coarser grid for zoning/majority filter
  nd_ng_seg <- terra::aggregate(
    nd_ng_smooth,
    fact = ndvi_agg_fact,
    fun  = mean,
    na.rm = TRUE
  )

  # continuous NDVI map on 2 m grid
  nd_ng_plot <- nd_ng_smooth

  nd_vals <- values(nd_ng_plot, na.rm = TRUE)
  if (length(nd_vals) == 0) {
    warning("NDVI has no valid values after smoothing/masking; disabling NDVI.")
    have_ndvi <- FALSE
  } else {
    nd_q <- as.numeric(quantile(nd_vals,
                                probs = c(0.02, 0.98),
                                na.rm  = TRUE))

    if (!all(is.finite(nd_q)) || nd_q[1] == nd_q[2]) {
      nd_zlim <- terra::global(nd_ng_plot, fun = range, na.rm = TRUE)[1, ]
    } else {
      nd_zlim <- nd_q
    }

    # Elevation + NDVI panel
    if (!is.null(plot_dir)) png(file.path(plot_dir, "plot_elev_ndvi_panel.png"), width = 1400, height = 700, res = 120)
    par(mfrow = c(1, 2), mar = c(3, 3, 3, 4))

    plot(dtm_field_2m,
         main   = "Elevation (2 m)",
         col    = pal_elev_cont,
         legend = TRUE,
         axes   = FALSE)
    lines(boundary_dtm)

    plot(
      nd_ng_plot,
      main   = paste0("NDVI (", date_label, ")"),
      axes   = FALSE,
      zlim   = nd_zlim,
      col    = pal_nd,
      legend = TRUE
    )
    lines(boundary_dtm, col = "black", lwd = 1.2)

    par(mfrow = c(1, 1))
    if (!is.null(plot_dir)) dev.off()
  }
} else {
  have_ndvi <- FALSE
}

# -------------------- K-MEANS ZONES (ELEV + NDVI if available) ----------------
# k-means with zone labels 1..k ordered from LOWEST to HIGHEST value
kmeans_zones_1d <- function(r, k, seed = 1234) {
  vals <- values(r, na.rm = FALSE)
  keep <- !is.na(vals)
  if (!any(keep)) stop("No non-NA cells for k-means.")

  x        <- as.numeric(vals[keep])
  x_scaled <- scale(x)

  if (!is.null(seed)) set.seed(seed)
  km <- kmeans(
    x_scaled,
    centers  = k,
    nstart   = 10,
    iter.max = 200,       # more iterations
    algorithm = "Lloyd"   # avoid Hartigan-Wong quick-transfer warnings
  )

  cluster_means <- tapply(x, km$cluster, mean)
  ord           <- order(cluster_means)       # low -> high

  new_clusters <- match(km$cluster, ord)      # map to 1..k

  cluster_r <- r
  all_vals  <- rep(NA_integer_, length(vals))
  all_vals[keep] <- new_clusters
  values(cluster_r) <- all_vals

  names(cluster_r) <- "zone"
  cluster_r
}

zones_elev_list <- list()
zones_ndvi_list <- list()

kmeans_amount_per_k <- 0.15 / length(k_range)

for (k in k_range) {
  k_str <- as.character(k)

  report(paste0("Computing elevation-based k-means zones for k = ", k), kmeans_amount_per_k)
  zones_elev_list[[k_str]] <- kmeans_zones_1d(dtm_field_2m, k = k)

  if (have_ndvi) {
    report(paste0("Computing NDVI-based k-means zones for k = ", k), kmeans_amount_per_k)
    zones_ndvi_list[[k_str]] <- kmeans_zones_1d(nd_ng_seg, k = k)
  }
}

# Majority filter (optional) to enforce minimum mapping unit
if (apply_majority_filter_elev ||
    (apply_majority_filter_ndvi && have_ndvi)) {

  # elevation window (2 m grid)
  cellsize_elev   <- res(dtm_field_2m)[1]
  win_cells_elev  <- max(3L, as.integer(round(min_mapping_unit_m / cellsize_elev)))
  if (win_cells_elev %% 2 == 0) win_cells_elev <- win_cells_elev + 1L
  w_mmu_elev      <- matrix(1, win_cells_elev, win_cells_elev)

  # NDVI window (aggregated grid) only if NDVI exists
  if (have_ndvi) {
    cellsize_ndvi   <- res(nd_ng_seg)[1]
    win_cells_ndvi  <- max(3L, as.integer(round(min_mapping_unit_m / cellsize_ndvi)))
    if (win_cells_ndvi %% 2 == 0) win_cells_ndvi <- win_cells_ndvi + 1L
    w_mmu_ndvi      <- matrix(1, win_cells_ndvi, win_cells_ndvi)

    report(
      paste0(
        "NDVI agg cellsize ~", round(cellsize_ndvi, 2),
        " m; majority window = ", win_cells_ndvi, "x", win_cells_ndvi, " cells"
      ),
      0.02
    )
  }

  majority_filter <- function(zr, w) {
    terra::focal(
      zr,
      w         = w,
      fun       = function(x, ...) {
        x <- x[!is.na(x)]
        if (length(x) == 0) return(NA)
        tab <- table(x)
        as.numeric(names(tab)[which.max(tab)])
      },
      na.rm     = TRUE,
      na.policy = "omit"
    )
  }

  majority_amount_per_k <- 0.1 / length(k_range)

  for (k in k_range) {
    k_str <- as.character(k)

    if (apply_majority_filter_elev) {
      report(paste0("Applying majority filter to elevation zones, k = ", k), majority_amount_per_k)
      zones_elev_list[[k_str]] <- majority_filter(zones_elev_list[[k_str]], w_mmu_elev)
    }

    if (apply_majority_filter_ndvi && have_ndvi) {
      report(paste0("Applying majority filter to NDVI zones, k = ", k), majority_amount_per_k)
      zones_ndvi_list[[k_str]] <- majority_filter(zones_ndvi_list[[k_str]], w_mmu_ndvi)
    }
  }
}

# terra-only polygons + optional smoothing (buffer); NDVI smoothing default OFF
zones_to_polygons_smooth_terra <- function(zone_raster,
                                           smooth_dist = 0,
                                           n_passes = 1) {
  v <- terra::as.polygons(zone_raster, dissolve = TRUE, na.rm = TRUE)

  if (!"zone" %in% names(v)) {
    first_attr <- names(v)[1]
    names(v)[names(v) == first_attr] <- "zone"
  }

  if (smooth_dist > 0 && n_passes > 0) {
    report(
      paste0("Smoothing polygons: dist = ", smooth_dist, " (", n_passes, " pass(es))"),
      0.01
    )
    for (i in seq_len(n_passes)) {
      v <- terra::buffer(v, width = smooth_dist)
      v <- terra::buffer(v, width = -smooth_dist)
    }
  }

  # crop/mask polygons to boundary to avoid smearing outside
  if (exists("boundary_dtm")) {
    v <- terra::crop(v, boundary_dtm)
    v <- terra::mask(v, boundary_dtm)
  }

  v
}

contours_vec_wgs <- project(contours_vec_dtm, target_crs)

contours_path <- file.path(
  out_dir,
  paste0(
    field_name,
    "_contours_2m_int",
    gsub("\\.", "p", format(interval_m)),
    "m_wgs84.shp"
  )
)

writeVector(contours_vec_wgs,
            contours_path,
            filetype = "ESRI Shapefile",
            overwrite = TRUE)

# --- write elevation & NDVI zones as shapefiles (with optional smoothing) ---
zones_elev_vec_dtm_list <- list()
zones_ndvi_vec_dtm_list <- list()

for (k in k_range) {
  k_str <- as.character(k)

  # Elevation zones: mild smoothing (1 pass, smooth_dist_elev)
  z_elev_r       <- zones_elev_list[[k_str]]
  z_elev_vec_dtm <- zones_to_polygons_smooth_terra(
    z_elev_r,
    smooth_dist = smooth_dist_elev,
    n_passes    = 1
  )
  zones_elev_vec_dtm_list[[k_str]] <- z_elev_vec_dtm

  z_elev_vec_wgs <- project(z_elev_vec_dtm, target_crs)
  z_elev_vec_wgs$Rate <- NA_real_

  elev_shp_path <- file.path(
    out_dir,
    paste0(field_name, "_zones_elev_2m_k", k, "_smooth_wgs84.shp")
  )

  writeVector(z_elev_vec_wgs,
              elev_shp_path,
              filetype = "ESRI Shapefile",
              overwrite = TRUE)

  # NDVI zones only if NDVI exists
  if (have_ndvi) {
    z_ndvi_r       <- zones_ndvi_list[[k_str]]
    z_ndvi_vec_dtm <- zones_to_polygons_smooth_terra(
      z_ndvi_r,
      smooth_dist = smooth_dist_ndvi,
      n_passes    = if (smooth_dist_ndvi > 0) 3L else 0L
    )
    zones_ndvi_vec_dtm_list[[k_str]] <- z_ndvi_vec_dtm

    z_ndvi_vec_wgs <- project(z_ndvi_vec_dtm, target_crs)
    z_ndvi_vec_wgs$Rate <- NA_real_

    ndvi_shp_path <- file.path(
      out_dir,
      paste0(field_name, "_zones_ndvi_agg", ndvi_agg_fact,
             "_k", k, "_smooth_wgs84.shp")
    )

    writeVector(z_ndvi_vec_wgs,
                ndvi_shp_path,
                filetype = "ESRI Shapefile",
                overwrite = TRUE)
  }
}

report(paste0("Elevation zone shapefiles (k = 2–5) written to: ", out_dir), 0.03)
if (have_ndvi) {
  report(paste0("NDVI-based zone shapefiles (k = 2–5) written to: ", out_dir), 0.03)
} else {
  report("NDVI shapefiles skipped (no Sentinel-2 scene available).", 0.01)
}
report(paste0("Stylized contours shapefile written to: ", contours_path), 0.02)

# --- multi-panel plots: elevation zones vs NDVI zones -------------------------
# Elevation zones (raster) – 1=lowest (dark), k=highest (yellow or red)
if (!is.null(plot_dir)) png(file.path(plot_dir, "plot_elev_zones_grid.png"), width = 1000, height = 1000, res = 120)
par(mfrow = c(2, 2), mar = c(3, 3, 3, 4))
for (k in k_range) {
  k_str <- as.character(k)
  z_r   <- zones_elev_list[[k_str]]
  cols  <- pal_elev_fun(k)

  plot(z_r,
       main   = paste("Elevation zones (2 m, k =", k, ")"),
       axes   = FALSE,
       col    = cols,
       legend = TRUE)
  lines(boundary_dtm)
}
par(mfrow = c(1, 1))
if (!is.null(plot_dir)) dev.off()

# NDVI zones: polygons – only if NDVI exists
if (have_ndvi) {
  if (!is.null(plot_dir)) png(file.path(plot_dir, "plot_ndvi_zones_grid.png"), width = 1000, height = 1000, res = 120)
  par(mfrow = c(2, 2), mar = c(3, 3, 3, 4))
  for (k in k_range) {
    k_str  <- as.character(k)
    v_ndvi <- zones_ndvi_vec_dtm_list[[k_str]]
    if (is.null(v_ndvi)) next

    cols_ndvi <- pal_ndvi_fun(k)   # 1 = yellow/red, k = dark/cool
    z_vals    <- sort(unique(v_ndvi$zone))
    zone_col  <- cols_ndvi[match(v_ndvi$zone, z_vals)]

    plot(v_ndvi,
         col    = zone_col,
         border = "black",
         main   = paste("NDVI zones (k =", k, ")"),
         axes   = FALSE)
    lines(boundary_dtm, lwd = 1.2)
  }
  par(mfrow = c(1, 1))
  if (!is.null(plot_dir)) dev.off()
} else {
  message("NDVI zone plots skipped (no Sentinel-2 scene available).")
}

# -------------------- FLEXIBLE 2.5D EXTRUDED MAP (ELEV or NDVI) ---------------
# source = "elev" -> elevation zones
# source = "ndvi" -> NDVI zones (only if have_ndvi == TRUE)
# k      = values present in k_range (must exist in zones_*_list)
# Example (after calling run_zone_pipeline() and keeping the result):
#   res <- run_zone_pipeline()
#   res$show_zones_3d()                          # elevation, k = 4
#   res$show_zones_3d(source = "elev", k = 3)
#   res$show_zones_3d(source = "ndvi", k = 3, exaggeration = 50)

show_zones_3d <- function(source       = c("elev", "ndvi"),
                          k            = 4,
                          exaggeration = 40) {
  source <- match.arg(source)

  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' is required for the 2.5D view (show_zones_3d).")
  }
  if (source == "ndvi" && !have_ndvi) {
    stop("NDVI zones are not available (Sentinel-2 fetch failed).")
  }

  k_str <- as.character(k)

  zr <- if (source == "elev") {
    zones_elev_list[[k_str]]
  } else {
    zones_ndvi_list[[k_str]]
  }
  if (is.null(zr)) stop("No zone raster found for source = ", source, ", k = ", k)

  # put zone raster on DTM grid for extrusion heights
  zone_r_dtm <- resample(zr, dtm_field_2m, method = "near")

  # source-dependent smoothing (same logic as shapefile export)
  if (source == "elev") {
    smooth_dist <- smooth_dist_elev
    n_passes    <- 1L
  } else {
    smooth_dist <- smooth_dist_ndvi
    n_passes    <- if (smooth_dist_ndvi > 0) 3L else 0L
  }

  zones_vec_dtm <- zones_to_polygons_smooth_terra(
    zone_r_dtm,
    smooth_dist = smooth_dist,
    n_passes    = n_passes
  )

  # mean elevation per zone for extrusion height (terrain, not NDVI)
  zs <- terra::zonal(dtm_field_2m, zone_r_dtm, fun = "mean", na.rm = TRUE)
  colnames(zs) <- c("zone", "mean_elev")

  sf <- getNamespace("sf")
  zones_sf_dtm <- sf::st_as_sf(zones_vec_dtm)
  zones_sf_dtm$zone <- as.integer(zones_sf_dtm$zone)
  zones_sf_dtm <- dplyr::left_join(zones_sf_dtm, as.data.frame(zs), by = "zone")

  if (any(is.na(zones_sf_dtm$mean_elev))) {
    zones_sf_dtm$mean_elev[is.na(zones_sf_dtm$mean_elev)] <-
      mean(zones_sf_dtm$mean_elev, na.rm = TRUE)
  }

  elev_vals <- zones_sf_dtm$mean_elev
  elev_min  <- min(elev_vals, na.rm = TRUE)
  elev_max  <- max(elev_vals, na.rm = TRUE)

  if (elev_max > elev_min) {
    zones_sf_dtm$height_m <- exaggeration * (elev_vals - elev_min) / (elev_max - elev_min)
  } else {
    zones_sf_dtm$height_m <- exaggeration / 2
  }

  if (!"Rate" %in% names(zones_sf_dtm)) {
    zones_sf_dtm$Rate <- NA_real_
  }

  zones_wgs84    <- sf::st_transform(zones_sf_dtm, 4326)
  boundary_wgs84 <- sf::st_transform(sf::st_as_sf(boundary), 4326)

  field_bounds <- sf::st_bbox(boundary_wgs84)
  field_center <- c(
    (field_bounds["xmin"] + field_bounds["xmax"]) / 2,
    (field_bounds["ymin"] + field_bounds["ymax"]) / 2
  )

  zone_vals <- sort(unique(zones_wgs84$zone))
  n_zone    <- length(zone_vals)

  # elevation colors: 1 (lowest) dark/cool, k (highest) yellow/red
  # NDVI colors: 1 (lowest) yellow/red, k (highest) dark/cool
  if (source == "elev") {
    zone_colors <- pal_elev_fun(n_zone)
  } else {
    zone_colors <- pal_ndvi_fun(n_zone)
  }

  zone_color_expr <- match_expr(
    column  = "zone",
    values  = zone_vals,
    stops   = unname(zone_colors),
    default = "#cccccc"
  )

  m <- suppressWarnings(
    maplibre(bounds = field_bounds) |>
      add_source(id = "zones", data = zones_wgs84) |>
      add_fill_extrusion_layer(
        id                     = "zones-3d",
        source                 = "zones",
        fill_extrusion_height  = get_column("height_m"),
        fill_extrusion_color   = zone_color_expr,
        fill_extrusion_opacity = 0.9
      ) |>
      add_symbol_layer(
        id               = "zone-labels",
        source           = "zones",
        text_field       = get_column("zone"),
        text_size        = 14,
        text_color       = "black",
        text_halo_color  = "white",
        text_halo_width  = 1.5,
        symbol_placement = "point",
        symbol_z_elevate = TRUE
      ) |>
      add_navigation_control(visualize_pitch = TRUE) |>
      add_scale_control(position = "bottom-left", unit = "metric") |>
      set_view(center = field_center, zoom = 15)
  )

  m
}

list(
  boundary                = boundary,
  boundary_dtm            = boundary_dtm,
  dtm_field_2m            = dtm_field_2m,
  field_name              = field_name,
  have_ndvi               = have_ndvi,
  s2_datetime             = s2_datetime,
  k_range                 = k_range,
  zones_elev_list         = zones_elev_list,
  zones_ndvi_list         = zones_ndvi_list,
  zones_elev_vec_dtm_list = zones_elev_vec_dtm_list,
  zones_ndvi_vec_dtm_list = zones_ndvi_vec_dtm_list,
  pal_elev_fun            = pal_elev_fun,
  pal_ndvi_fun            = pal_ndvi_fun,
  contours_path           = contours_path,
  out_dir                 = out_dir,
  plot_dir                = plot_dir,
  show_zones_3d           = show_zones_3d
)

}

## To run standalone (same behaviour as before this refactor):
## Note: deliberately does NOT also check interactive() here - this file is
## auto-sourced by Shiny's loadSupport() (R/ directory convention) whenever
## the app is launched from an interactive R/RStudio session, and
## interactive() reflects the whole session, not just code typed at the
## console, so it can't be used to distinguish those two cases.
if (!isTRUE(getOption("hrdem_ndvi_zones.skip_autorun", FALSE))) {
  result <- run_zone_pipeline()
  ##  for 2.5D:
  # result$show_zones_3d(source = "elev", k = 3)
}
