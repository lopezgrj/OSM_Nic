# Download OSM file
# Specify URL where file is stored
url <- "http://download.geofabrik.de/central-america/nicaragua-latest.osm.pbf"

raw_data_dir <- "./raw_data"
destfile <- file.path(raw_data_dir, "nicaragua-latest.osm.pbf")
# Apply download.file function in R
download.file(url, destfile)


# Record the run timestamp for downstream checks and automation.
last_download_path <- file.path(raw_data_dir, "lastdownloadOSMData.txt")
last_download_text <- format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
writeLines(last_download_text, con = last_download_path)

# OGR2OGR
system("ogr2ogr -f SQLite -lco FORMAT=WKT ./data/nicaragua.sqlite ./raw_data/nicaragua-latest.osm.pbf", intern=T)


# Record the run timestamp for downstream checks and automation.
last_update_path <- "./data/lastupdate.txt"
last_update_text <- format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
writeLines(last_update_text, con = last_update_path)

library(DBI)
library(duckdb)
con <- dbConnect(duckdb(), dbdir = "./data/nicaragua.duckdb")
dbExecute(con, "INSTALL spatial;")
dbExecute(con, "LOAD spatial;")
dbExecute(con, "INSTALL sqlite;")
dbExecute(con, "LOAD sqlite;")
dbExecute(con, "ATTACH './data/nicaragua.sqlite' AS osm_sqlite (TYPE sqlite);")

# Copy every OSM table produced by ogr2ogr into the DuckDB database.
source_tables <- dbGetQuery(
  con,
  "
  SELECT table_name
  FROM information_schema.tables
  WHERE table_catalog = 'osm_sqlite'
    AND table_schema = 'main'
    AND table_type = 'BASE TABLE'
  ORDER BY table_name;
  "
)

if (nrow(source_tables) == 0) {
  stop("No source tables found in ./data/nicaragua.sqlite. Check ogr2ogr output.")
}

for (tbl_name in source_tables$table_name) {
  dst_tbl <- dbQuoteIdentifier(con, tbl_name)
  src_tbl <- dbQuoteIdentifier(con, tbl_name)
  dbExecute(
    con,
    paste0(
      "CREATE OR REPLACE TABLE ",
      dst_tbl,
      " AS SELECT * FROM osm_sqlite.",
      src_tbl,
      ";"
    )
  )
}

dbExecute(con, "DETACH osm_sqlite;")

# Validation: list saved tables in the DuckDB main schema.
saved_tables <- dbGetQuery(
  con,
  "
  SELECT table_name
  FROM information_schema.tables
  WHERE table_schema = 'main'
    AND table_type = 'BASE TABLE'
  ORDER BY table_name;
  "
)
print(saved_tables)

dbDisconnect(con, shutdown = TRUE)

