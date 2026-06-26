# ============================================================
# Web harness for hrdem_ndvi_zones.R
#
# Thin orchestration layer used by app.R (Shiny). Does not modify
# hrdem_ndvi_zones.R; it sources it once (with the skip_autorun option set so
# the default top-level run doesn't fire) to get run_zone_pipeline() into
# scope, then drives it per-session: stages an uploaded boundary into a
# session directory, calls run_zone_pipeline() with the user's dial values
# and that session directory as both out_dir and plot_dir, and returns a
# uniform success/error result for the Shiny server to render.
#
# The skip-autorun signal is passed via options() rather than a plain
# variable: hrdem_ndvi_zones.R's autorun check runs inside a source() call
# (so the assignment must land somewhere it will reliably look), and
# options() is process-global state that is unaffected by exactly which
# environment a given source()/sourcing-wrapper chain happens to evaluate
# code in (e.g. when this file is itself sourced from inside Shiny's own
# app-loading environment rather than .GlobalEnv).
# ============================================================

options(hrdem_ndvi_zones.skip_autorun = TRUE)
source(file.path("R", "hrdem_ndvi_zones.R"), local = FALSE)

#' Stage uploaded boundary file(s) into a session directory.
#'
#' Shiny's fileInput() gives each uploaded file a randomized temp name and a
#' separate $name (original filename). For a shapefile upload, the sidecar
#' files (.shx/.dbf/.prj/.cpg) must share the same basename as the .shp for
#' GDAL/terra::vect() to read it correctly, so every uploaded file is copied
#' into session_dir under its *original* basename (shared across the set),
#' derived from whichever uploaded file ends in .shp, or the first file's
#' name otherwise.
#'
#' @param upload_df data.frame as produced by a fileInput with multiple = TRUE
#'   (columns: name, datapath, ...).
#' @param session_dir destination directory.
#' @return normalized path to the staged main boundary file.
stage_boundary_upload <- function(upload_df, session_dir) {
  if (is.null(upload_df) || nrow(upload_df) == 0) {
    stop("No boundary file uploaded.")
  }

  shp_row <- which(grepl("\\.shp$", upload_df$name, ignore.case = TRUE))
  main_idx <- if (length(shp_row) > 0) shp_row[1] else 1L
  main_basename <- tools::file_path_sans_ext(upload_df$name[main_idx])

  staged_main_path <- NULL
  for (i in seq_len(nrow(upload_df))) {
    ext <- tools::file_ext(upload_df$name[i])
    dest_name <- paste0(main_basename, ".", ext)
    dest_path <- file.path(session_dir, dest_name)
    file.copy(upload_df$datapath[i], dest_path, overwrite = TRUE)
    if (i == main_idx) staged_main_path <- dest_path
  }

  normalizePath(staged_main_path, mustWork = TRUE)
}

#' Run the zoning pipeline for one Shiny session/request.
#'
#' @param upload_df fileInput data.frame for the boundary upload.
#' @param dials named list of run_zone_pipeline() arguments supplied by the UI
#'   (palette_mode, k_range, ndvi_median_size, ndvi_agg_fact,
#'   apply_majority_filter_elev, apply_majority_filter_ndvi,
#'   min_mapping_unit_m, s2_cloud_max, s2_months, s2_year,
#'   s2_max_month_offset, contour_interval, smooth_dist_elev,
#'   smooth_dist_ndvi).
#' @param session_dir per-session directory; reused as both out_dir and
#'   plot_dir so shapefiles and plot PNGs land in one place for zipping/serving.
#' @return list(success = TRUE/FALSE, error = NULL/string, result = NULL/list)
run_pipeline_for_session <- function(upload_df, dials, session_dir) {
  # Clear any outputs from a previous run in this session so displayed
  # results/downloads always match the current dial settings.
  old_outputs <- list.files(
    session_dir,
    pattern = "\\.(shp|shx|dbf|prj|cpg)$|^plot_.*\\.png$",
    full.names = TRUE
  )
  if (length(old_outputs) > 0) unlink(old_outputs)

  tryCatch(
    {
      boundary_path <- stage_boundary_upload(upload_df, session_dir)

      pipeline_args <- c(
        list(
          boundary_path = boundary_path,
          out_dir       = session_dir,
          plot_dir      = session_dir
        ),
        dials
      )

      result <- do.call(run_zone_pipeline, pipeline_args)

      list(success = TRUE, error = NULL, result = result)
    },
    error = function(e) {
      list(success = FALSE, error = conditionMessage(e), result = NULL)
    }
  )
}
