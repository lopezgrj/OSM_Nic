# OSM Nicaragua Data and Explorer Specification

## 1. Document status

This document defines the current contract for the OSM Nicaragua data
pipeline and local Shiny applications. Requirements are marked:

- **Implemented**: present in the current code and part of the acceptance
  baseline.
- **Planned**: desired behavior that is not yet guaranteed by the code.
- **Optional**: not required for the main Nicaragua workflow.

Normative terms have the following meanings:

- **Shall**: mandatory for a requirement to pass acceptance.
- **Should**: recommended but not required for acceptance.
- **May**: optional behavior.

Known defects and unstable implementation details are documented in Section
11. They are not requirements.

## 2. Purpose and goals

The project downloads OpenStreetMap (OSM) extracts, converts the Nicaragua
extract into local databases, and provides Shiny interfaces for mapping,
filtering, exporting, and inspecting the resulting data.

The project shall support a local analyst or researcher who needs to:

1. Download a Geofabrik PBF extract.
2. Import the Nicaragua extract into SQLite and DuckDB.
3. Browse spatial features and filter them by OSM tags.
4. Export matching features to GeoPackage.
5. Inspect database tables, columns, sample rows, and tag distributions.

The project is not a hosted or multi-user production service.

## 3. Scope

### 3.1 Included

- A Geofabrik PBF download helper.
- A Shiny downloader for selecting Geofabrik extracts.
- An OSM import pipeline that creates SQLite and DuckDB databases.
- A primary Shiny application in `app.R` with map and tag explorers.
- Standalone database and tag explorers.
- An optional Taginfo download and conversion script.
- An example analysis in `Nature_Reserves.R`.

### 3.2 Excluded

- Public hosting or deployment.
- User accounts, authentication, authorization, or access-control roles.
- Editing OSM features or uploading changes to OpenStreetMap.
- Scheduled downloads or imports.
- Concurrent database writers or multi-user isolation.
- Guaranteed complete tag counts when `other_tags` sampling is enabled.
- A committed copy of downloaded extracts or generated databases.

The repository does not contain `osm_plot_app.R` or
`osm_logic_explorer_app.R`. The primary application is `app.R`.

## 4. Architecture and data flow

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
                                                       +--> Shiny apps
                                                       +--> R analysis
                                                       +--> GeoPackage export
```

The standard workflow uses:

- `raw_data/nicaragua-latest.osm.pbf`
- `data/nicaragua.sqlite`
- `data/nicaragua.duckdb`
- `data/lastupdate.txt`

Applications and scripts use project-relative paths and shall be run from the
project root unless a helper accepts an explicit `project_dir`.

## 5. Runtime compatibility

### 5.1 Reference environment

The following development environment was observed on 2026-10-18. These
versions identify the environment used for local inspection; they are not a
validated compatibility baseline. Versions outside this environment are not
guaranteed until automated compatibility checks exist.

| Component | Reference version |
|---|---:|
| R | 4.6.1 |
| Shiny | 1.14.0 |
| DBI | 1.3.0 |
| DuckDB R package | 1.5.6 |
| sf | 1.1.3 |
| leaflet | 2.2.3 |
| curl R package | 8.1.0 |
| jsonlite | 2.0.0 |
| ggplot2 | 4.0.3 |
| GDAL/OGR | 3.13.3 |

`terra` is required only by the example analysis and was not installed in the
recorded reference environment.

### 5.2 Platform and external dependencies

- The reference platform is macOS.
- `ogr2ogr` shall be available on `PATH` for imports.
- The DuckDB `spatial` and `sqlite` extensions shall be installed and
  loadable before import.
- The Geofabrik catalog loader requires the `curl` command-line program and
  `env` on `PATH`.
- Internet access is required for downloads, extension installation, and
  OpenStreetMap Mapnik tiles.
- The project should adopt `renv.lock` before claiming reproducible package
  resolution across machines.

## 6. Data contracts

### 6.1 Source PBF

| Property | Contract |
|---|---|
| Standard path | `raw_data/nicaragua-latest.osm.pbf` |
| Standard source | `https://download.geofabrik.de/central-america/nicaragua-latest.osm.pbf` |
| Validity check | File exists and size is greater than zero |
| Ownership | Generated local artifact; not source code |

### 6.2 Feature tables

Feature-table names depend on GDAL/OGR output. Common names are `points`,
`lines`, `multilinestrings`, `multipolygons`, and `other_relations`.

| Column | Contract |
|---|---|
| `WKT_GEOMETRY` | Required for map-selectable tables; WKT interpreted as EPSG:4326 |
| `ogc_fid` | Optional feature identifier and preferred future stable ordering key |
| `osm_id` | Optional OSM identifier |
| `osm_way_id` | Optional OSM way identifier |
| `z_order` | Optional rendering/order attribute |
| `other_tags` | Optional serialized OSM key/value collection |
| Other columns | Treated as candidate direct-tag columns |

The current parser recognizes `other_tags` entries serialized as
`"key"=>"value"`. Embedded unescaped double quotes are not supported by the
parser. Null and empty values shall not contribute to direct-column tag
counts.

Invalid or empty WKT may be returned by the source database. Map loading and
export shall surface geometry-conversion failures rather than reporting
success with invalid output.

### 6.3 Import metadata

`osm_import_metadata` shall contain exactly one row after a successful import.

| Column | DuckDB type | Meaning |
|---|---|---|
| `source_url` | `VARCHAR` | Reported source URL |
| `pbf_path` | `VARCHAR` | Normalized local PBF path |
| `pbf_size_bytes` | `BIGINT` | PBF size at import |
| `pbf_modified_at` | `TIMESTAMP` | PBF modification time |
| `ogr_version` | `VARCHAR` | `ogr2ogr --version` output |
| `imported_at` | `TIMESTAMP` | Import completion timestamp |

### 6.4 Generated outputs

| Resource | Format and purpose |
|---|---|
| `data/nicaragua.sqlite` | OGR-converted feature database with WKT geometry |
| `data/nicaragua.duckdb` | Main local query database |
| `data/taginfo-db.duckdb` | Optional Taginfo database |
| `data/lastupdate.txt` | Successful import time |
| `raw_data/lastdownloadOSMData.txt` | Successful PBF download time |
| `raw_data/lastdownloadTagDB.txt` | Successful optional Taginfo run time |
| GeoPackage download | All features matching the applied map query |

## 7. Functional requirements

### 7.1 PBF download helper

- **DL-001 — Implemented:** `download_osm_data()` shall default to the latest
  Nicaragua Geofabrik PBF.
- **DL-002 — Implemented:** The helper shall create `<project_dir>/raw_data/`
  when needed and save the requested file there.
- **DL-003 — Implemented:** The transfer shall use a temporary file and
  replace the destination only after a non-empty transfer succeeds.
- **DL-004 — Implemented:** The helper shall use the R `curl` package when
  installed and otherwise use `download.file()`.
- **DL-005 — Implemented:** Transfer, empty-output, and replacement failures
  shall terminate with an error.
- **DL-006 — Implemented:** A successful transfer shall update
  `raw_data/lastdownloadOSMData.txt`.

### 7.2 Geofabrik downloader application

- **GEO-001 — Implemented:** The application shall load and refresh
  Geofabrik's live PBF catalog.
- **GEO-002 — Implemented:** Catalog selection shall populate the URL and file
  name while allowing manual entry.
- **GEO-003 — Implemented:** URLs shall use HTTPS, target
  `download.geofabrik.de`, and end in `.pbf`.
- **GEO-004 — Implemented:** File names shall be simple `.pbf` names without
  directory components.
- **GEO-005 — Implemented:** Downloads shall target the working directory's
  `raw_data/` folder.
- **GEO-006 — Implemented:** The application shall show progress, status,
  resulting size, and modification time.
- **GEO-007 — Implemented:** Catalog and transfer failures shall be visible to
  the user.

### 7.3 OSM import pipeline

- **IMP-001 — Implemented:** `import_osm_data()` shall read
  `raw_data/nicaragua-latest.osm.pbf` under `project_dir`.
- **IMP-002 — Implemented:** Import shall fail explicitly when the PBF,
  `data/` directory, `ogr2ogr`, DuckDB extensions, or usable feature tables
  are unavailable.
- **IMP-003 — Implemented:** `ogr2ogr` shall create a temporary SQLite
  database with WKT geometry, and the existing SQLite destination shall be
  replaced only after non-empty conversion output is produced.
- **IMP-004 — Implemented:** The importer shall exclude
  `geometry_columns`, `spatial_ref_sys`, and `sqlite_sequence` from the
  DuckDB feature-table copy.
- **IMP-005 — Implemented:** DuckDB feature-table replacement and metadata
  updates shall execute in one transaction.
- **IMP-006 — Implemented:** A failed DuckDB transaction shall roll back
  DuckDB changes.
- **IMP-007 — Implemented:** A successful import shall write the metadata
  contract in Section 6.3 and update `data/lastupdate.txt`.
- **IMP-008 — Implemented:** Temporary SQLite output shall be removed after
  success or failure.
- **IMP-009 — Planned:** The entire SQLite and DuckDB pair shall be published
  atomically so that a DuckDB failure cannot leave a new SQLite database
  paired with an older DuckDB database.
- **IMP-010 — Planned:** Feature tables removed from a later PBF conversion
  shall also be removed from DuckDB.

### 7.4 Primary application: map explorer

- **MAP-001 — Implemented:** `app.R` shall open
  `data/nicaragua.duckdb` read-only.
- **MAP-002 — Implemented:** The layer selector shall include main-schema
  tables containing `WKT_GEOMETRY`.
- **MAP-003 — Implemented:** Filtering shall support direct columns,
  `other_tags`, and all tag sources.
- **MAP-004 — Implemented:** Value matching shall support case-insensitive
  **Contains** and **Exact** modes.
- **MAP-005 — Implemented:** Expressions shall support `AND`, `OR`, `&`, and
  `||`, with `AND` binding more tightly than `OR`.
- **MAP-006 — Implemented:** Matching outer single or double quotes shall
  prevent operator words from being parsed and shall be removed from the
  literal term.
- **MAP-007 — Implemented:** Filters shall be applied only when **Load layer**
  is selected.
- **MAP-008 — Implemented:** Statistics shall report total, matching, and
  map-loaded rows.
- **MAP-009 — Implemented:** Map loading shall be limited to the selected
  value from 100 through 100,000 rows.
- **MAP-010 — Implemented:** WKT shall be interpreted as EPSG:4326 and point,
  line, and polygon geometries shall render on an OpenStreetMap Mapnik
  basemap.
- **MAP-011 — Implemented:** Preview output shall contain no more than ten
  loaded rows and shall omit `WKT_GEOMETRY`.
- **MAP-012 — Implemented:** GeoPackage export shall include all matching
  rows, not only map-loaded rows.
- **MAP-013 — Implemented:** Export shall fail visibly when no matching rows
  or usable geometry exist.
- **MAP-014 — Planned:** Export shall use an immutable snapshot of the layer
  and filter state applied by the most recent successful **Load layer**
  action.
- **MAP-015 — Planned:** Limited map queries shall use stable ordering by
  `ogc_fid` when present and a documented fallback otherwise.
- **MAP-016 — Planned:** `%` and `_` shall be escaped in **Contains** input so
  they match literal characters unless a future explicit wildcard mode is
  selected.

#### Map filter semantics

- In direct-column and `other_tags` modes, every term in an `AND` group
  applies to the selected source.
- In **Any** mode, separate terms may match separate direct columns or
  `other_tags`.
- An empty direct-column value matches non-empty values in that column.
- An empty `other_tags` value matches rows containing the selected key.
- An empty **Any** value matches rows with at least one non-empty tag field.

### 7.5 Primary application: tag explorer

- **TAG-001 — Implemented:** Direct-column summaries shall scan all rows.
- **TAG-002 — Implemented:** `other_tags` summaries shall parse at most the
  selected limit, from 100 through 500,000 non-null rows per table.
- **TAG-003 — Implemented:** Filters shall include table, inferred feature
  group, key, value, match mode, and minimum occurrence count.
- **TAG-004 — Implemented:** Views shall include keys, values, storage
  locations, and filtered summary rows.
- **TAG-005 — Implemented:** Refreshing or changing the parse limit shall
  recompute summaries.
- **TAG-006 — Implemented:** Summary failures shall produce an error
  notification.
- **TAG-007 — Planned:** Sampled `other_tags` queries shall use the stable
  ordering contract from MAP-015.
- **TAG-008 — Planned:** Summary output shall explicitly display whether each
  count is complete or sampled.

The primary application defers initial tag-summary computation until
**Refresh** is selected or the parse limit changes.

Feature groups are inferred as follows:

| Tables | Feature group |
|---|---|
| `points` | `point` |
| `lines`, `multilinestrings` | `line` |
| `multipolygons` | `polygon` |
| `other_relations` | `relation` |
| Any other table | `other` |

### 7.6 Standalone database explorer

- **DBX-001 — Implemented:** `osm_db_explorer_app.R` shall open the local
  DuckDB database read-only.
- **DBX-002 — Implemented:** It shall show main-schema row counts, column
  counts, and `WKT_GEOMETRY` presence.
- **DBX-003 — Implemented:** It shall show column metadata and a configurable
  sample from 5 through 500 rows.
- **DBX-004 — Implemented:** It shall list information-schema tables and
  columns and allow table-choice refresh.
- **DBX-005 — Implemented:** It shall stop explicitly when no main-schema
  tables exist.
- **DBX-006 — Planned:** Refresh shall update all overview outputs, not only
  the table selector.

### 7.7 Standalone tag explorer

- **STAG-001 — Implemented:** `osm_tag_explorer_app.R` shall open
  `data/nicaragua.duckdb` read-only.
- **STAG-002 — Implemented:** It shall provide the filtering and summary
  behavior defined by TAG-001 through TAG-005.
- **STAG-003 — Implemented:** It shall compute summaries at startup.

### 7.8 Optional Taginfo database

- **TINFO-001 — Optional:** `code/downloadTaginfodb.R` may download the
  compressed Taginfo SQLite database, retry incomplete downloads, decompress
  it, and copy its tables to `data/taginfo-db.duckdb`.
- **TINFO-002 — Optional:** A successful run shall update
  `raw_data/lastdownloadTagDB.txt`.

### 7.9 Example analysis

- **EX-001 — Optional:** `Nature_Reserves.R` may read
  `data/nicaragua.sqlite` and demonstrate selection and plotting of features
  such as parks, nature reserves, and pharmacies.

## 8. Error and recovery requirements

- **ERR-001 — Implemented:** Missing required inputs and external tools shall
  produce explicit errors.
- **ERR-002 — Implemented:** Failed or empty downloads shall not replace an
  existing destination.
- **ERR-003 — Implemented:** Failed OGR conversion shall not replace an
  existing SQLite database.
- **ERR-004 — Implemented:** Failed DuckDB copying shall roll back the active
  DuckDB transaction.
- **ERR-005 — Implemented:** Temporary download and SQLite files shall be
  removed during function exit.
- **ERR-006 — Planned:** Disk-space requirements shall be checked before
  conversion and database replacement.
- **ERR-007 — Planned:** Interrupted publication shall recover either the
  complete previous database pair or the complete new database pair.
- **ERR-008 — Planned:** Invalid individual geometries should be reported with
  table and feature identifiers and should not be silently discarded.

## 9. Operational and non-functional requirements

- **NFR-001 — Implemented:** Shiny query connections and the database explorer
  shall be read-only.
- **NFR-002 — Implemented:** Map materialization shall be bounded by the
  100-to-100,000-row UI limit.
- **NFR-003 — Implemented:** `other_tags` parsing shall be bounded by the
  100-to-500,000-row-per-table UI limit.
- **NFR-004 — Implemented:** GeoPackage export shall remain complete and is
  therefore not bounded by the map limit; it may require memory proportional
  to all matching rows.
- **NFR-005 — Planned:** For a reference database of at most 10 GB on the
  reference environment, the primary application should expose its initial
  UI within 30 seconds without computing tag summaries.
- **NFR-006 — Planned:** Long-running import, summary, and export operations
  should expose progress and cancellation where supported.
- **NFR-007 — Planned:** Automated acceptance shall record elapsed time, peak
  memory, input database size, and output row count so performance regressions
  can be compared without treating machine-dependent timings as universal.

No public-service availability, geographic freshness, or concurrent-user SLA
is defined.

## 10. Licensing and attribution

The source code is distributed under the repository's MIT License.

OSM-derived data is subject to the OpenStreetMap Open Database License (ODbL)
and attribution requirements.

- **LIC-001 — Implemented:** Interactive maps shall use the Leaflet
  OpenStreetMap Mapnik provider so tile attribution is displayed.
- **LIC-002 — Implemented:** Import metadata shall preserve the source URL and
  import timestamp.
- **LIC-003 — Planned:** GeoPackage exports should include source URL,
  import timestamp, and ODbL attribution metadata when the output format and
  writer support it.
- **LIC-004 — Planned:** User-facing export documentation should include
  OpenStreetMap attribution and a link to the ODbL.

Users remain responsible for satisfying license obligations when distributing
generated databases, exports, or derivative works.

## 11. Known limitations

- **KL-001:** Export uses the last loaded filter clause with the currently
  selected layer. Changing the layer without loading it can create a
  mismatched query. MAP-014 defines the intended correction.
- **KL-002:** Limited map and sampled `other_tags` queries have no explicit
  row ordering. Results may vary between executions. MAP-015 and TAG-007
  define the intended correction.
- **KL-003:** In `other_tags` **Contains** mode, serialized text after the
  selected key is searched; text in a later tag may satisfy the match.
- **KL-004:** `%` and `_` are currently passed to SQL `LIKE` and act as
  wildcards. MAP-016 defines literal matching as the intended behavior.
- **KL-005:** `other_tags` parsing recognizes only simple
  `"key"=>"value"` pairs and does not support embedded unescaped quotes.
- **KL-006:** A new SQLite database is published before the DuckDB copy
  completes, so the pair can become inconsistent after a DuckDB failure.
- **KL-007:** Import creates or replaces discovered DuckDB tables but does not
  remove obsolete feature tables absent from a later import.
- **KL-008:** GeoPackage export loads every matching row into memory.
- **KL-009:** Compatibility has not been validated across environments. The
  observed development environment is recorded in Section 5, but no
  multi-platform CI matrix exists.
- **KL-010:** The repository does not currently provide an automated test
  suite or a committed deterministic fixture database.

## 12. Quick start

Run commands from the project root.

```r
install.packages(c(
  "shiny", "DBI", "duckdb", "sf", "leaflet", "curl", "jsonlite"
))

source("code/downloadOSMData.R")
download_osm_data()

source("code/importOSMData.R")
import_osm_data()

shiny::runApp("app.R")
```

Install DuckDB extensions before the first import:

```r
con <- DBI::dbConnect(duckdb::duckdb())
DBI::dbExecute(con, "INSTALL spatial;")
DBI::dbExecute(con, "INSTALL sqlite;")
DBI::dbDisconnect(con, shutdown = TRUE)
```

Other entry points:

```r
shiny::runApp("geofabrik_downloader_app.R")
shiny::runApp("osm_db_explorer_app.R")
shiny::runApp("osm_tag_explorer_app.R")
source("code/downloadTaginfodb.R")
```

## 13. Acceptance plan and traceability

Automated fixture-based tests are planned but not yet present. Until they are
added, the following checks form the manual baseline.

| Check | Requirement IDs | Input and action | Expected result |
|---|---|---|---|
| A-01 Download success | DL-001–DL-006 | Download the standard PBF | Non-empty destination and updated timestamp file |
| A-02 Download failure | DL-003, DL-005, ERR-002 | Use an unreachable URL while an existing destination is present | Explicit error; existing destination unchanged |
| A-03 Downloader validation | GEO-001–GEO-007 | Refresh catalog; test valid and invalid URL/file-name combinations | Selection populates fields; invalid input rejected; success shows file metadata |
| A-04 Import success | IMP-001–IMP-008 | Import a valid standard PBF with required extensions | SQLite and DuckDB updated; metadata has one complete row; timestamp written |
| A-05 Import conversion failure | IMP-003, ERR-003, ERR-005 | Force `ogr2ogr` failure while an existing SQLite database is present | Explicit error; existing SQLite unchanged; temporary file absent |
| A-06 DuckDB rollback | IMP-005, IMP-006, ERR-004 | Force a table-copy failure inside the transaction | Explicit error; no partial DuckDB transaction committed |
| A-07 Map startup | MAP-001, MAP-002, MAP-010 | Start `app.R` with at least one WKT table | Layer is selectable and Mapnik basemap renders |
| A-08 Filter semantics | MAP-003–MAP-008 | Use a controlled database with documented rows covering exact, contains, AND, OR, symbols, and quoted operators | Matching count equals the documented expected count for each expression |
| A-09 Display bound | MAP-009, MAP-011, NFR-002 | Match more rows than the selected limit | Loaded rows do not exceed limit; preview has at most ten rows and no WKT column |
| A-10 Export | MAP-012, MAP-013 | Export more matches than the map limit, then export an empty match | GeoPackage contains every match; empty match reports an error |
| A-11 Tag summaries | TAG-001–TAG-006 | Refresh summaries and change parse limit | Direct and sampled counts appear; limit change recomputes; errors are visible |
| A-12 Database explorer | DBX-001–DBX-005 | Open valid and empty databases | Metadata and samples shown for valid DB; empty DB stops explicitly |
| A-13 Standalone tags | STAG-001–STAG-003 | Start standalone tag explorer | Startup summary and filters operate against read-only DB |
| A-14 Attribution | LIC-001, LIC-002 | Inspect map and import metadata | Tile attribution is visible; source URL and import time are retained |

A deterministic fixture should include:

- At least one point, line, and polygon table.
- Stable `ogc_fid` values.
- Null, empty, valid, and invalid WKT.
- Direct-tag values covering case, `%`, `_`, `AND`, and `OR`.
- `other_tags` rows containing multiple keys and empty values.
- More rows than the smallest map and parsing limits.

When fixture tests are added, each test name shall include the associated
requirement ID, and CI results shall be the authoritative acceptance record.
