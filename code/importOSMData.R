import_osm_data <- function(
  project_dir = getwd(),
  source_url = "https://download.geofabrik.de/central-america/nicaragua-latest.osm.pbf"
) {
  pbf_path <- file.path(project_dir, "raw_data", "nicaragua-latest.osm.pbf")
  data_dir <- file.path(project_dir, "data")
  sqlite_path <- file.path(data_dir, "nicaragua.sqlite")
  temporary_sqlite_path <- paste0(sqlite_path, ".tmp")
  duckdb_path <- file.path(data_dir, "nicaragua.duckdb")

  if (!file.exists(pbf_path)) {
    stop("OSM PBF not found at ", pbf_path, ". Run download_osm_data() first.")
  }
  if (!dir.exists(data_dir)) {
    stop("Data directory not found at ", data_dir, ".")
  }

  ogr_path <- Sys.which("ogr2ogr")
  if (!nzchar(ogr_path)) {
    stop("ogr2ogr was not found on PATH. Install GDAL/OGR before importing.")
  }

  unlink(temporary_sqlite_path)
  on.exit(unlink(temporary_sqlite_path), add = TRUE)
  ogr_status <- system2(
    ogr_path,
    args = c("-f", "SQLite", "-lco", "FORMAT=WKT", temporary_sqlite_path, pbf_path)
  )
  temporary_size <- file.info(temporary_sqlite_path)$size
  if (ogr_status != 0 || is.na(temporary_size) || temporary_size == 0) {
    stop("ogr2ogr failed to create a valid SQLite database.")
  }
  if (!file.rename(temporary_sqlite_path, sqlite_path)) {
    stop("Could not replace the existing SQLite database at ", sqlite_path, ".")
  }

  library(DBI)
  library(duckdb)
  con <- dbConnect(duckdb(), dbdir = duckdb_path)
  sqlite_attached <- FALSE
  transaction_started <- FALSE
  on.exit({
    if (!is.null(con)) {
      if (transaction_started) {
        try(dbRollback(con), silent = TRUE)
      }
      if (sqlite_attached) {
        try(dbExecute(con, "DETACH osm_sqlite;"), silent = TRUE)
      }
      try(dbDisconnect(con, shutdown = TRUE), silent = TRUE)
    }
  }, add = TRUE)

  dbExecute(con, "LOAD spatial;")
  dbExecute(con, "LOAD sqlite;")
  dbExecute(con, paste0("ATTACH ", dbQuoteString(con, sqlite_path), " AS osm_sqlite (TYPE sqlite);"))
  sqlite_attached <- TRUE

  source_tables <- dbGetQuery(
    con,
    "
    SELECT table_name
    FROM information_schema.tables
    WHERE table_catalog = 'osm_sqlite'
      AND table_schema = 'main'
      AND table_type = 'BASE TABLE'
      AND table_name NOT IN ('geometry_columns', 
                             'spatial_ref_sys',
                             'sqlite_sequence')
    ORDER BY table_name;
    "
  )
  if (nrow(source_tables) == 0) {
    stop("No OSM feature tables found in ", sqlite_path, ".")
  }

  dbBegin(con)
  transaction_started <- TRUE
  for (tbl_name in source_tables$table_name) {
    table_id <- dbQuoteIdentifier(con, tbl_name)
    dbExecute(
      con,
      paste0(
        "CREATE OR REPLACE TABLE ", table_id,
        " AS SELECT * FROM osm_sqlite.", table_id, ";"
      )
    )
  }

  ogr_version <- system2(ogr_path, "--version", stdout = TRUE, stderr = TRUE)
  pbf_info <- file.info(pbf_path)
  dbExecute(
    con,
    "CREATE TABLE IF NOT EXISTS osm_import_metadata (source_url VARCHAR, pbf_path VARCHAR, pbf_size_bytes BIGINT, pbf_modified_at TIMESTAMP, ogr_version VARCHAR, imported_at TIMESTAMP);"
  )
  dbExecute(con, "DELETE FROM osm_import_metadata;")
  dbExecute(
    con,
    "INSERT INTO osm_import_metadata VALUES (?, ?, ?, ?, ?, ?);",
    params = list(
      source_url,
      normalizePath(pbf_path),
      as.numeric(pbf_info$size),
      as.POSIXct(pbf_info$mtime),
      paste(ogr_version, collapse = " "),
      Sys.time()
    )
  )
  dbCommit(con)
  transaction_started <- FALSE

  dbExecute(con, "DETACH osm_sqlite;")
  sqlite_attached <- FALSE
  saved_tables <- dbGetQuery(
    con,
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name;"
  )
  print(saved_tables)
  dbDisconnect(con, shutdown = TRUE)
  con <- NULL

  last_update_path <- file.path(data_dir, "lastupdate.txt")
  writeLines(format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), con = last_update_path)
  invisible(saved_tables)
}