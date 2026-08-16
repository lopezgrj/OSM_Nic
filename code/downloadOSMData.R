download_osm_data <- function(
  project_dir = getwd(),
  source_url = "https://download.geofabrik.de/central-america/nicaragua-latest.osm.pbf",
  file_name = "nicaragua-latest.osm.pbf",
  progress_callback = NULL
) {
  raw_data_dir <- file.path(project_dir, "raw_data")
  dir.create(raw_data_dir, recursive = TRUE, showWarnings = FALSE)

  destfile <- file.path(raw_data_dir, file_name)
  temporary_file <- tempfile("geofabrik-", tmpdir = raw_data_dir, fileext = ".pbf")
  on.exit(unlink(temporary_file), add = TRUE)

  if (requireNamespace("curl", quietly = TRUE)) {
    handle <- curl::new_handle()
    curl::handle_setopt(
      handle,
      proxy = "",
      followlocation = TRUE,
      timeout = 3600,
      connecttimeout = 60,
      low_speed_time = 120,
      low_speed_limit = 1024
    )
    if (!is.null(progress_callback)) {
      curl::handle_setopt(
        handle,
        progressfunction = function(downloaded, uploaded) {
          if (downloaded[1] > 0) {
            progress_callback(min(downloaded[2] / downloaded[1], 1))
          }
          TRUE
        }
      )
    }

    response <- tryCatch(
      curl::curl_fetch_disk(source_url, temporary_file, handle = handle),
      error = function(error) {
        stop("Geofabrik transfer failed: ", error$message, call. = FALSE)
      }
    )
    download_status <- if (
      response$status_code == 0 ||
        (response$status_code >= 200 && response$status_code < 300)
    ) 0 else 1
  } else {
    old_timeout <- getOption("timeout")
    options(timeout = 3600)
    on.exit(options(timeout = old_timeout), add = TRUE)
    download_status <- download.file(source_url, temporary_file, mode = "wb")
  }
  temporary_size <- file.info(temporary_file)$size
  if (download_status != 0 || is.na(temporary_size) || temporary_size == 0) {
    http_status <- if (exists("response") && !is.null(response)) response$status_code else "unknown"
    stop(
      "PBF download failed or produced an empty file (HTTP status ",
      http_status,
      ").",
      call. = FALSE
    )
  }

  if (!file.rename(temporary_file, destfile)) {
    stop("Could not replace the existing PBF at ", destfile, ".")
  }

  last_download_path <- file.path(raw_data_dir, "lastdownloadOSMData.txt")
  writeLines(format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), con = last_download_path)
  invisible(destfile)
}