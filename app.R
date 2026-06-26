# ============================================================
# Shiny web app for hrdem_ndvi_zones.R
#
# Lets a user upload a field boundary, adjust the zoning "dials" via
# sliders/inputs, run the pipeline, view plots and the 3D zone view, and
# download the output shapefiles. Drives R/hrdem_ndvi_zones.R exclusively
# through R/web_harness.R; neither file is modified by this app.
# ============================================================

# Shiny auto-sources every *.R file in an R/ directory next to app.R via
# loadSupport(), before app.R's own code below runs. R/hrdem_ndvi_zones.R
# has side effects when sourced with its defaults (network fetches, writing
# shapefiles), so that auto-load must be disabled; web_harness.R sources it
# explicitly and deliberately instead, once the option is set. This must be
# the first line of this file (not left to .Rprofile alone) since it has to
# run before loadSupport() does, regardless of whether .Rprofile happened to
# be picked up for the current R session.
options(shiny.autoload.r = FALSE)

library(shiny)
library(bslib)
library(zip)
library(mapgl)

source(file.path("R", "web_harness.R"))

current_year <- as.integer(format(Sys.Date(), "%Y"))

ui <- page_sidebar(
  title = "Elevation + NDVI Zone Mapping",
  sidebar = sidebar(
    width = 360,

    fileInput(
      "boundary_file", "Field boundary",
      multiple = TRUE,
      accept = c(".geojson", ".json", ".shp", ".shx", ".dbf", ".prj", ".cpg", ".gpkg", ".kml")
    ),
    helpText(
      "Upload a GeoJSON/GPKG/KML file, or a full shapefile set ",
      "(.shp + .shx + .dbf + .prj, select all at once). ",
      "Need to draw a boundary? Try ",
      a("geojson.io", href = "https://geojson.io", target = "_blank"),
      " and upload the exported GeoJSON."
    ),

    accordion(
      open = c("Palette", "Zones"),

      accordion_panel(
        "Palette",
        radioButtons(
          "palette_mode", "Colour palette",
          choices = c("Turbo" = "turbo", "Viridis" = "viridis"),
          selected = "turbo"
        )
      ),

      accordion_panel(
        "Zones",
        sliderInput("k_range", "Number of zones (k)", min = 2, max = 8, value = c(2, 5), step = 1)
      ),

      accordion_panel(
        "NDVI processing",
        sliderInput("ndvi_median_size", "NDVI smoothing window (odd)", min = 1, max = 9, value = 3, step = 2),
        numericInput("ndvi_agg_fact", "NDVI aggregation factor", value = 2, min = 1, max = 10, step = 1)
      ),

      accordion_panel(
        "Majority filter (minimum mapping unit)",
        checkboxInput("apply_majority_filter_elev", "Apply to elevation zones", value = FALSE),
        checkboxInput("apply_majority_filter_ndvi", "Apply to NDVI zones", value = TRUE),
        numericInput("min_mapping_unit_m", "Minimum mapping unit (m)", value = 30, min = 1)
      ),

      accordion_panel(
        "Sentinel-2 search",
        numericInput("s2_cloud_max", "Max cloud cover (%)", value = 20, min = 0, max = 100),
        selectizeInput(
          "s2_months", "Preferred month(s)",
          choices = setNames(1:12, month.name), selected = 8, multiple = TRUE
        ),
        numericInput("s2_year", "Year (blank = current year)", value = NA, min = 2015, max = current_year),
        sliderInput("s2_max_month_offset", "Search window (+/- months)", value = 3, min = 0, max = 6)
      ),

      accordion_panel(
        "Contours & smoothing",
        numericInput("contour_interval", "Contour interval (m)", value = 0.5, min = 0.1, step = 0.1),
        numericInput("smooth_dist_elev", "Elevation zone smoothing distance (m)", value = 3, min = 0),
        numericInput("smooth_dist_ndvi", "NDVI zone smoothing distance (m)", value = 0, min = 0)
      )
    ),

    actionButton("run", "Run analysis", class = "btn-primary"),
    br(), br(),
    uiOutput("status_message")
  ),

  navset_tab(
    nav_panel("Elevation",
      imageOutput("plot_elevation"),
      imageOutput("plot_contours")
    ),
    nav_panel("NDVI",
      uiOutput("ndvi_panel_ui")
    ),
    nav_panel("Zone maps",
      imageOutput("plot_elev_zones_grid"),
      uiOutput("ndvi_zones_grid_ui")
    ),
    nav_panel("3D view",
      fluidRow(
        column(4, selectInput("zone_source_3d", "Source", choices = c("Elevation" = "elev"))),
        column(4, selectInput("zone_k_3d", "k", choices = character(0))),
        column(4, numericInput("exaggeration_3d", "Height exaggeration", value = 40, min = 1))
      ),
      actionButton("render_3d", "Render 3D view"),
      br(), br(),
      conditionalPanel(
        "output.has_3d_view == false",
        p("Run the analysis, then click \"Render 3D view\".")
      ),
      maplibreOutput("zones3d", height = "75vh")
    ),
    nav_panel("Downloads",
      uiOutput("downloads_ui")
    )
  )
)

server <- function(input, output, session) {

  session_dir <- file.path(tempdir(), paste0("zones_", session$token))
  dir.create(session_dir, recursive = TRUE, showWarnings = FALSE)
  session$onSessionEnded(function() {
    unlink(session_dir, recursive = TRUE, force = TRUE)
  })

  run_state <- reactiveVal(NULL)  # list(success, error, result) from web_harness

  observeEvent(input$run, {
    req(input$boundary_file)

    s2_year_val <- if (is.na(input$s2_year)) NULL else as.integer(input$s2_year)

    dials <- list(
      palette_mode               = input$palette_mode,
      k_range                    = seq(input$k_range[1], input$k_range[2]),
      ndvi_median_size           = as.integer(input$ndvi_median_size),
      ndvi_agg_fact              = as.integer(input$ndvi_agg_fact),
      apply_majority_filter_elev = input$apply_majority_filter_elev,
      apply_majority_filter_ndvi = input$apply_majority_filter_ndvi,
      min_mapping_unit_m         = input$min_mapping_unit_m,
      s2_cloud_max               = input$s2_cloud_max,
      s2_months                  = as.integer(input$s2_months),
      s2_year                    = s2_year_val,
      s2_max_month_offset        = as.integer(input$s2_max_month_offset),
      contour_interval           = input$contour_interval,
      smooth_dist_elev           = input$smooth_dist_elev,
      smooth_dist_ndvi           = input$smooth_dist_ndvi
    )

    run_state(NULL)

    withProgress(message = "Running zone analysis", value = 0, {
      incProgress(0.1, detail = "Fetching elevation + boundary...")
      out <- run_pipeline_for_session(input$boundary_file, dials, session_dir)
      incProgress(0.9, detail = "Done")
      run_state(out)
    })

    if (isTRUE(out_have_ndvi(run_state()))) {
      updateSelectInput(session, "zone_source_3d", choices = c("Elevation" = "elev", "NDVI" = "ndvi"))
    } else {
      updateSelectInput(session, "zone_source_3d", choices = c("Elevation" = "elev"))
    }

    rs <- run_state()
    if (isTRUE(rs$success)) {
      k_choices <- as.character(rs$result$k_range)
      updateSelectInput(session, "zone_k_3d", choices = k_choices, selected = k_choices[1])
    }
  })

  out_have_ndvi <- function(rs) {
    if (is.null(rs) || !isTRUE(rs$success)) return(FALSE)
    isTRUE(rs$result$have_ndvi)
  }

  output$status_message <- renderUI({
    rs <- run_state()
    if (is.null(rs)) return(NULL)
    if (isTRUE(rs$success)) {
      ndvi_note <- if (isTRUE(rs$result$have_ndvi)) {
        sprintf("NDVI available (Sentinel-2 scene: %s).", sub("T.*$", "", rs$result$s2_datetime %||% ""))
      } else {
        "NDVI shapefiles skipped (no suitable Sentinel-2 scene available)."
      }
      div(class = "text-success", paste("Run complete.", ndvi_note))
    } else {
      div(class = "text-danger", paste("Run failed:", rs$error))
    }
  })

  `%||%` <- function(a, b) if (!is.null(a) && nzchar(a)) a else b

  render_block_image <- function(filename, label) {
    renderImage({
      rs <- run_state()
      shiny::validate(shiny::need(isTRUE(rs$success), "Run the analysis to see this plot."))
      path <- file.path(session_dir, filename)
      shiny::validate(shiny::need(file.exists(path), paste(label, "was not generated for this run.")))
      list(src = path, contentType = "image/png", width = "100%")
    }, deleteFile = FALSE)
  }

  output$plot_elevation        <- render_block_image("plot_elevation.png", "Elevation plot")
  output$plot_contours         <- render_block_image("plot_contours.png", "Contour plot")
  output$plot_elev_zones_grid  <- render_block_image("plot_elev_zones_grid.png", "Elevation zone grid")

  output$ndvi_panel_ui <- renderUI({
    rs <- run_state()
    if (is.null(rs) || !isTRUE(rs$success)) {
      return(p("Run the analysis to see NDVI results."))
    }
    if (!isTRUE(rs$result$have_ndvi)) {
      return(p(class = "text-muted", "NDVI shapefiles skipped (no suitable Sentinel-2 scene available)."))
    }
    imageOutput("plot_elev_ndvi_panel")
  })
  output$plot_elev_ndvi_panel <- render_block_image("plot_elev_ndvi_panel.png", "Elevation/NDVI panel")

  output$ndvi_zones_grid_ui <- renderUI({
    rs <- run_state()
    if (is.null(rs) || !isTRUE(rs$success)) return(NULL)
    if (!isTRUE(rs$result$have_ndvi)) {
      return(p(class = "text-muted", "NDVI zone plots skipped (no suitable Sentinel-2 scene available)."))
    }
    imageOutput("plot_ndvi_zones_grid")
  })
  output$plot_ndvi_zones_grid <- render_block_image("plot_ndvi_zones_grid.png", "NDVI zone grid")

  rendered_3d <- reactiveVal(NULL)

  observeEvent(input$render_3d, {
    rs <- run_state()
    req(isTRUE(rs$success))
    req(input$zone_k_3d)

    widget <- tryCatch(
      rs$result$show_zones_3d(
        source       = input$zone_source_3d,
        k            = as.integer(input$zone_k_3d),
        exaggeration = input$exaggeration_3d
      ),
      error = function(e) {
        showNotification(paste("3D view failed:", conditionMessage(e)), type = "error")
        NULL
      }
    )
    rendered_3d(widget)
  })

  output$zones3d <- renderMaplibre({
    widget <- rendered_3d()
    shiny::validate(shiny::need(!is.null(widget), ""))
    widget
  })

  output$has_3d_view <- reactive({
    !is.null(rendered_3d())
  })
  outputOptions(output, "has_3d_view", suspendWhenHidden = FALSE)

  output$downloads_ui <- renderUI({
    rs <- run_state()
    if (is.null(rs) || !isTRUE(rs$success)) {
      return(p("Run the analysis to download results."))
    }
    tagList(
      p(sprintf("Field: %s", rs$result$field_name)),
      downloadButton("download_all", "Download all shapefiles (.zip)")
    )
  })

  output$download_all <- downloadHandler(
    filename = function() {
      rs <- run_state()
      paste0(rs$result$field_name %||% "field", "_zones_outputs.zip")
    },
    content = function(file) {
      shp_files <- list.files(
        session_dir,
        pattern = "\\.(shp|shx|dbf|prj|cpg)$",
        full.names = FALSE
      )
      zip::zip(file, files = shp_files, root = session_dir)
    },
    contentType = "application/zip"
  )
}

shinyApp(ui, server)
