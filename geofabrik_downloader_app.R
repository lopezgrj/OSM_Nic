library(shiny)

source(file.path("code", "downloadOSMData.R"), local = TRUE)
download_helper <- get("download_osm_data", mode = "function")

default_url <- "https://download.geofabrik.de/central-america/nicaragua-latest.osm.pbf"
catalog_url <- "https://download.geofabrik.de/index-v1-nogeom.json"

read_geofabrik_catalog <- function() {
  temporary_file <- tempfile("geofabrik-index-", fileext = ".json")
  on.exit(unlink(temporary_file), add = TRUE)
  curl_path <- Sys.which("curl")
  if (!nzchar(curl_path)) {
    stop("curl was not found on PATH; cannot load the Geofabrik catalog.")
  }

  env_path <- Sys.which("env")
  download_status <- system2(
    env_path,
    args = c(
      "-u", "http_proxy", "-u", "https_proxy",
      "-u", "HTTP_PROXY", "-u", "HTTPS_PROXY",
      "-u", "all_proxy", "-u", "ALL_PROXY",
      curl_path,
      "--location", "--fail", "--silent", "--show-error",
      "--user-agent", "OSM_Nic-Geofabrik-downloader",
      "--output", temporary_file,
      catalog_url
    )
  )
  if (download_status != 0 || !file.exists(temporary_file) || file.info(temporary_file)$size == 0) {
    stop("Geofabrik catalog download failed.")
  }

  catalog <- jsonlite::fromJSON(temporary_file, simplifyVector = FALSE)
  extracts <- lapply(catalog$features, function(feature) {
    properties <- feature$properties
    pbf_url <- properties$urls$pbf
    if (is.null(pbf_url) || length(pbf_url) == 0 || !nzchar(pbf_url)) {
      return(NULL)
    }

    data.frame(
      id = properties$id %||% "",
      name = properties$name %||% properties$id %||% "Unnamed extract",
      parent = properties$parent %||% "",
      url = pbf_url,
      file_name = basename(pbf_url),
      stringsAsFactors = FALSE
    )
  })

  extracts <- Filter(Negate(is.null), extracts)
  if (length(extracts) == 0) {
    stop("Geofabrik returned no PBF extracts.")
  }

  do.call(rbind, extracts)
}

`%||%` <- function(value, fallback) {
  if (is.null(value) || length(value) == 0 || !nzchar(value[[1]])) fallback else value[[1]]
}

format_bytes <- function(bytes) {
  if (is.na(bytes) || bytes < 1) {
    return("Not downloaded")
  }

  units <- c("B", "KB", "MB", "GB")
  unit_index <- min(floor(log(bytes, base = 1024)) + 1, length(units))
  value <- bytes / 1024^(unit_index - 1)
  paste(format(round(value, 1), trim = TRUE, nsmall = 1), units[unit_index])
}

ui <- fluidPage(
  tags$head(
    tags$style(HTML("
      body { background: #f3f0e8; color: #1d2b28; font-family: Georgia, serif; }
      .container-fluid { max-width: 960px; padding: 48px 28px; }
      h1 { color: #164b43; font-size: 38px; margin-bottom: 8px; }
      .lede { color: #5c6b63; font-size: 17px; margin-bottom: 30px; }
      .download-panel { background: #fffdf8; border: 1px solid #d8d5ca; border-radius: 6px;
        box-shadow: 0 10px 28px rgba(29, 43, 40, .08); padding: 28px; }
      .control-label { color: #164b43; font-size: 15px; }
      .form-control { border-color: #c8cec5; border-radius: 3px; }
      .btn-primary { background: #d45d38; border-color: #c7512e; border-radius: 3px;
        font-weight: bold; padding: 10px 18px; }
      .btn-primary:hover, .btn-primary:focus { background: #b94a2d; border-color: #a64127; }
      .status { background: #edf3ec; border-left: 4px solid #4e8873; border-radius: 2px;
        margin-top: 22px; padding: 14px 16px; white-space: pre-wrap; }
      .metadata { color: #5c6b63; font-size: 14px; margin-top: 18px; }
    "))
  ),
  h1("Geofabrik extract downloader"),
  p(class = "lede", "Download an OpenStreetMap PBF extract into this project's raw_data folder."),
  div(class = "download-panel",
    actionButton("refresh_extracts", "Refresh available extracts"),
    selectizeInput(
      "extract",
      "Available PBF extracts",
      choices = character(0),
      selected = NULL,
      options = list(placeholder = "Search Geofabrik extracts...")
    ),
    div(class = "metadata", textOutput("catalog_status")),
    textInput(
      "source_url",
      "Geofabrik download URL",
      value = default_url,
      width = "100%"
    ),
    textInput(
      "file_name",
      "File name",
      value = "nicaragua-latest.osm.pbf",
      width = "100%"
    ),
    actionButton("download", "Download extract", class = "btn-primary"),
    div(class = "status", textOutput("status")),
    div(class = "metadata", textOutput("file_info"))
  )
)

server <- function(input, output, session) {
  download_state <- reactiveVal(list(message = "Ready to download.", path = NULL))
  extract_catalog <- reactiveVal(data.frame())

  output$catalog_status <- renderText({
    catalog <- extract_catalog()
    if (nrow(catalog) == 0) {
      return("The extract list is not loaded yet.")
    }
    paste(nrow(catalog), "PBF extracts available from Geofabrik.")
  })

  observeEvent(input$refresh_extracts, {
    tryCatch({
      catalog <- read_geofabrik_catalog()
      extract_catalog(catalog)

      labels <- ifelse(
        nzchar(catalog$parent),
        paste0(catalog$name, " (", catalog$parent, ")"),
        catalog$name
      )
      choices <- setNames(catalog$url, labels)
      selected_url <- if (default_url %in% catalog$url) default_url else catalog$url[[1]]
      updateSelectizeInput(session, "extract", choices = choices, selected = selected_url, server = TRUE)
      updateTextInput(session, "source_url", value = selected_url)
      updateTextInput(session, "file_name", value = basename(selected_url))
    }, error = function(error) {
      download_state(list(message = paste("Could not load Geofabrik extracts:", error$message), path = NULL))
    })
  }, ignoreInit = FALSE)

  observeEvent(input$extract, {
    catalog <- extract_catalog()
    if (nrow(catalog) == 0 || is.null(input$extract) || !input$extract %in% catalog$url) {
      return()
    }

    selected <- catalog[catalog$url == input$extract, , drop = FALSE][1, ]
    updateTextInput(session, "source_url", value = selected$url)
    updateTextInput(session, "file_name", value = selected$file_name)
  })

  output$status <- renderText(download_state()$message)

  output$file_info <- renderText({
    state <- download_state()
    if (is.null(state$path) || !file.exists(state$path)) {
      return("Destination: raw_data/")
    }

    info <- file.info(state$path)
    paste0(
      "Saved as ", basename(state$path),
      " | ", format_bytes(info$size),
      " | ", format(info$mtime, "%Y-%m-%d %H:%M:%S")
    )
  })

  observeEvent(input$download, {
    url <- trimws(input$source_url)
    file_name <- trimws(input$file_name)

    if (!grepl("^https://download\\.geofabrik\\.de/.+\\.pbf$", url, ignore.case = TRUE)) {
      download_state(list(message = "Enter a valid HTTPS Geofabrik .pbf URL.", path = NULL))
      return()
    }
    if (!grepl("^[A-Za-z0-9][A-Za-z0-9._-]*\\.pbf$", file_name, ignore.case = TRUE)) {
      download_state(list(message = "Use a simple .pbf file name without folders.", path = NULL))
      return()
    }

    destination <- file.path(getwd(), "raw_data", file_name)
    download_state(list(message = paste0("Downloading from Geofabrik...\nDestination: ", destination), path = NULL))

    tryCatch({
      withProgress(message = "Downloading extract", value = 0, {
        downloaded_path <- download_helper(
          project_dir = getwd(),
          source_url = url,
          file_name = file_name,
          progress_callback = function(value) {
            setProgress(value, detail = paste0(round(value * 100), "% downloaded"))
          }
        )
      })
      download_state(list(message = "Download complete.", path = downloaded_path))
    }, error = function(error) {
      download_state(list(message = paste("Download failed:", error$message), path = NULL))
    })
  })
}

shinyApp(ui, server)