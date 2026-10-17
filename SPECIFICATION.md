# OSM Nicaragua Data and Explorer Specification

## 1. Purpose

This project downloads OpenStreetMap (OSM) extracts, converts the Nicaragua
extract into local databases, and provides Shiny interfaces for mapping,
searching, and inspecting the resulting data. It is intended for local data
exploration and analysis, not as a hosted or multi-user production service.

This document describes the behavior implemented in the repository. It does
not imply that untracked data files or applications are part of the delivered
project.

## 2. Scope

The project includes:

- A Geofabrik PBF downloader helper and a Shiny interface for selecting and
  downloading available Geofabrik extracts.
- An OSM import pipeline that creates a SQLite database from a local PBF file
  and copies its feature tables into DuckDB.
- A primary Shiny app with a map explorer and a tag-summary explorer.
- A standalone DuckDB schema/table explorer.
- A standalone tag explorer.
- An optional script that downloads the OpenStreetMap Taginfo database and
  converts it to DuckDB.
- A small R analysis script demonstrating extraction and plotting of selected
  Nicaragua features.

The current primary app is `app.R`. The project does not contain tracked
`osm_plot_app.R` or `osm_logic_explorer_app.R` applications.

## 3. Users and use cases

The intended user is an analyst or researcher working locally with OSM data.
Typical tasks are:

1. Obtain a Geofabrik PBF extract.
2. Import the Nicaragua extract into SQLite and DuckDB.
3. Browse spatial features and filter them by OSM tag values.
4. Export all matching features to GeoPackage for use in GIS software.
5. Inspect database tables, columns, and sample rows.
6. Explore the distribution and storage location of tags.

## 4. System context and data flow

```text
Geofabrik PBF
    |
    +--> raw_data/<extract>.osm.pbf
               |
               +--> GDAL/OGR ogr2ogr
                         |
                         +--> data/nicaragua.sqlite
                                   |
                                   +--> DuckDB SQLite extension
                                             |
                                             +--> data/nicaragua.duckdb
                                                       |
                                                       +--> Shiny apps / analysis
```

The standard Nicaragua workflow uses `raw_data/nicaragua-latest.osm.pbf`,
`data/nicaragua.sqlite`, and `data/nicaragua.duckdb`. These are local generated
artifacts; they are not required to be committed to source control. The
application and import scripts expect to be run with the project root as the
working directory unless a helper explicitly accepts a `project_dir`.

## 5. Functional requirements

### 5.1 PBF download helper

The `download_osm_data()` helper shall:

- Download an extract from its supplied URL, defaulting to the latest
  Nicaragua Geofabrik PBF.
- Save the file under `<project_dir>/raw_data/` using the requested file name.
- Transfer through a temporary file and replace the destination only after a
  non-empty download succeeds.
- Use the `curl` R package when installed, including progress callbacks when
  supplied; otherwise use R's `download.file()`.
- Report transfer and replacement failures as errors.
- Record a successful download time in
  `<project_dir>/raw_data/lastdownloadOSMData.txt`.

### 5.2 Geofabrik downloader app

The `geofabrik_downloader_app.R` interface shall:

- Load Geofabrik's live catalog of PBF extracts and allow refreshing it.
- Provide searchable extract selection and populate the URL and file name from
  the selection.
- Allow manual URL and file-name entry.
- Accept only HTTPS URLs on `download.geofabrik.de` ending in `.pbf`.
- Accept only a simple `.pbf` file name without directory components.
- Download into the current working directory's `raw_data/` folder and show
  progress, status, and resulting file size and modification time.
- Show a user-visible status when catalog loading or downloading fails.

The app requires network access to Geofabrik and the `curl` command-line
program to load the catalog. PBF transfer itself uses the download helper.

### 5.3 OSM import pipeline

The `import_osm_data()` helper shall:

- Read `raw_data/nicaragua-latest.osm.pbf` from the given project directory.
- Require `ogr2ogr` to be available on `PATH`.
- Convert the PBF to a temporary SQLite database with WKT geometry output,
  then replace `data/nicaragua.sqlite` only if conversion succeeds.
- Attach the SQLite database to DuckDB and copy its feature tables into
  `data/nicaragua.duckdb`.
- Exclude SQLite spatial metadata and sequence tables from the feature-table
  copy.
- Store import metadata in `osm_import_metadata`, including source URL, PBF
  path and size, PBF modification time, OGR version, and import time.
- Write the completion time to `data/lastupdate.txt`.
- Fail explicitly when the PBF, data directory, OGR executable, or usable
  source feature tables are missing, or when conversion/copy fails.

The imported tables are expected to include a `WKT_GEOMETRY` column for use by
the map explorer. Common layer names include `points`, `lines`,
`multilinestrings`, `multipolygons`, and `other_relations`; actual tables
depend on the source extract and conversion.

### 5.4 Primary Shiny app: map explorer

The Map Explorer tab in `app.R` shall:

- Read `./data/nicaragua.duckdb` in read-only mode.
- Offer selectable feature tables containing `WKT_GEOMETRY`.
- Support three tag sources:
  - **Direct column:** search a selected attribute column.
  - **other_tags:** search a specified key within the `other_tags` field.
  - **Any:** search direct tag columns and `other_tags`.
- Support case-insensitive **Contains** and **Exact** value matching.
- Support Boolean value expressions using `AND`/`OR` or `&`/`||`; quoted
  literals allow operator words to be searched as text.
- Apply filters when the user selects **Load layer**.
- Show total table rows, matching rows, and rows loaded for display.
- Limit map-loaded features using the configurable maximum, whose interface
  range is 100 to 100,000 rows.
- Convert WKT geometry using EPSG:4326 and render point, line, and polygon
  features on a Leaflet map with labels.
- Show a preview of the first ten loaded rows, omitting the WKT geometry
  column.
- Export all matching features—not just the map display limit—to a
  GeoPackage. The export shall fail visibly if there is no matching feature
  data or geometry.

### 5.5 Primary Shiny app: tag explorer

The Tag Explorer tab in `app.R` shall:

- Summarize tag values from direct attribute columns and parsed `other_tags`
  entries across database tables.
- Allow the user to set a parsing limit for `other_tags` rows per table
  (interface range: 100 to 500,000).
- Filter summaries by table, inferred feature group, tag key, tag value,
  matching mode, and minimum occurrence count.
- Provide views of tag keys, tag values, storage locations, and filtered raw
  summary rows.
- Recompute summaries on refresh or when the parsing limit changes.
- Report summary-loading errors through an error notification.

Feature groups are inferred from conventional layer names: points, lines and
multilinestrings, multipolygons, other_relations, or other.
`other_tags` summaries are based on the configured sample limit, so they may
not represent every row in a large table.

### 5.6 Standalone database explorer

The `osm_db_explorer_app.R` app shall open the local DuckDB database read-only
and provide:

- A main-schema table overview with row count, column count, and an indicator
  for `WKT_GEOMETRY`.
- A table explorer with column metadata and a configurable sample of rows
  (interface range: 5 to 500).
- Information-schema listings of tables and columns.
- A refresh action for table choices.

The app shall stop with an explicit error if the database has no main-schema
tables.

### 5.7 Standalone tag explorer

The `osm_tag_explorer_app.R` app provides a separate interface for tag
summaries. It shall:

- Read `./data/nicaragua.duckdb` in read-only mode.
- Generate tag counts from direct columns and sampled `other_tags` fields.
- Filter by table, inferred feature group, key, value, match mode, and minimum
  count.
- Display tag key, value, location, and filtered-row summaries.
- Refresh the computed summaries on request or when the `other_tags` parsing
  limit changes.

### 5.8 Optional Taginfo database

The optional `code/downloadTaginfodb.R` script shall download the Taginfo
compressed SQLite database, retry incomplete downloads, decompress it, and
copy its tables to `data/taginfo-db.duckdb`. It shall record the successful
run time in `raw_data/lastdownloadTagDB.txt`. This database is separate from
the Nicaragua OSM database and is not required by the primary app.

### 5.9 Example analysis

`Nature_Reserves.R` is an example analysis, not an application entry point. It
reads `data/nicaragua.sqlite` and demonstrates selecting and plotting
features such as parks, nature reserves, and pharmacies.

## 6. Data and external interfaces

| Resource | Purpose | Source or format |
|---|---|---|
| `raw_data/nicaragua-latest.osm.pbf` | Nicaragua source extract | Geofabrik OSM PBF |
| `data/nicaragua.sqlite` | OGR-converted local feature database | SQLite with WKT geometry |
| `data/nicaragua.duckdb` | Main query database for Shiny apps | DuckDB |
| `data/taginfo-db.duckdb` | Optional Taginfo data | DuckDB copied from Taginfo SQLite |
| Geofabrik catalog | List of available PBF extracts | Live JSON endpoint |
| GeoPackage download | Filtered map-explorer output | OGC GeoPackage |

OSM-derived data is subject to OpenStreetMap's Open Database License (ODbL)
and attribution requirements. Users are responsible for observing those terms
when downloading, distributing, or using generated data.

## 7. Runtime requirements

Required R packages vary by entry point:

- Main app: `shiny`, `DBI`, `duckdb`, `sf`, and `leaflet`.
- Geofabrik downloader app/helper: `shiny`, `jsonlite`, and `curl` (the
  helper has a `download.file()` fallback if the `curl` R package is absent).
- Database explorer: `shiny`, `DBI`, and `duckdb`.
- Tag explorer: `shiny`, `DBI`, and `duckdb`.
- Import: `DBI`, `duckdb`, GDAL/OGR `ogr2ogr`, plus DuckDB `spatial` and
  `sqlite` extensions.
- Example analysis: `sf`, `terra`, and `ggplot2`.

Internet access is required for source downloads and for the map's online
CartoDB Positron tiles. The applications use project-relative database paths,
so run them from the project root. The repository targets a local R
environment; no deployment, authentication, authorization, or concurrent
writer behavior is specified.

## 8. Operational and quality requirements

- Database explorer and Shiny query connections shall be read-only.
- Downloads and database imports shall surface errors rather than silently
  report success for missing or empty output.
- Import conversion uses a temporary SQLite output and a DuckDB transaction
  for copied tables and metadata.
- Large source data and generated databases may require substantial disk space
  and memory; no fixed performance SLA is defined.
- Map rendering is bounded by the configured display-row limit; GeoPackage
  export is not bounded by that map limit.
- The applications are designed for an interactive local user and do not
  promise multi-user isolation or concurrent database refreshes.

## 9. Out of scope

- Hosting or deploying the apps as a public service.
- User accounts, authentication, or access-control roles.
- Editing OSM features or uploading changes to OpenStreetMap.
- Automated scheduled downloads or imports.
- Guaranteeing complete tag counts when `other_tags` sampling is limited.
- A fixed geographic freshness or performance service-level objective.
- A committed copy of source extracts, generated databases, or Taginfo data.
