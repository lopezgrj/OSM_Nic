library(shiny)
library(DBI)
library(duckdb)
library(sf)
library(leaflet)

# Helper functions for tag exploration
SYSTEM_TABLES <- c("geometry_columns", "spatial_ref_sys", "sqlite_sequence")
NON_TAG_COLUMNS <- c(
  "ogc_fid", "WKT_GEOMETRY", "osm_id", "osm_way_id", "z_order"
)

infer_feature_group <- function(table_name) {
  if (table_name == "points") {
    return("point")
  }
  if (table_name %in% c("lines", "multilinestrings")) {
    return("line")
  }
  if (table_name == "multipolygons") {
    return("polygon")
  }
  if (table_name == "other_relations") {
    return("relation")
  }
  "other"
}

get_tables <- function(con) {
  tbls <- dbGetQuery(
    con,
    "
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'main'
      AND table_type = 'BASE TABLE'
    ORDER BY table_name;
    "
  )$table_name

  setdiff(tbls, SYSTEM_TABLES)
}

extract_other_tag_pairs <- function(tag_string) {
  if (is.na(tag_string) || !nzchar(tag_string)) {
    return(data.frame(key = character(0), value = character(0), stringsAsFactors = FALSE))
  }

  matches <- regmatches(tag_string, gregexpr('"[^"]+"=>"[^"]*"', tag_string, perl = TRUE))[[1]]
  if (length(matches) == 0) {
    return(data.frame(key = character(0), value = character(0), stringsAsFactors = FALSE))
  }

  keys <- sub('^"([^"]+)"=>".*$', '\\1', matches)
  values <- sub('^"[^"]+"=>"([^"]*)"$', '\\1', matches)
  data.frame(key = keys, value = values, stringsAsFactors = FALSE)
}

parse_other_tags <- function(tag_strings) {
  pieces <- lapply(tag_strings, extract_other_tag_pairs)
  pieces <- pieces[vapply(pieces, nrow, integer(1)) > 0]

  if (length(pieces) == 0) {
    return(data.frame(key = character(0), value = character(0), stringsAsFactors = FALSE))
  }

  do.call(rbind, pieces)
}

get_other_tags_counts <- function(con, table_name, parse_limit) {
  cols <- get_table_columns(con, table_name)
  if (!("other_tags" %in% cols)) {
    return(data.frame())
  }

  other_tags <- dbGetQuery(
    con,
    paste0(
      "SELECT other_tags FROM ",
      dbQuoteIdentifier(con, table_name),
      " WHERE other_tags IS NOT NULL LIMIT ",
      as.integer(parse_limit),
      ";"
    )
  )$other_tags

  pairs <- parse_other_tags(other_tags)
  if (nrow(pairs) == 0) {
    return(data.frame())
  }

  counts <- as.data.frame(table(pairs$key, pairs$value), stringsAsFactors = FALSE)
  counts <- counts[counts$Freq > 0, , drop = FALSE]
  names(counts) <- c("tag_key", "tag_value", "n")

  data.frame(
    table_name = table_name,
    feature_group = infer_feature_group(table_name),
    storage_source = "other_tags",
    tag_key = counts$tag_key,
    tag_value = counts$tag_value,
    n = as.numeric(counts$n),
    stringsAsFactors = FALSE
  )
}

get_direct_tag_counts <- function(con, table_name) {
  cols <- get_table_columns(con, table_name)
  candidate_cols <- setdiff(cols, c(NON_TAG_COLUMNS, "other_tags"))

  if (length(candidate_cols) == 0) {
    return(data.frame())
  }

  counts <- lapply(candidate_cols, function(col_name) {
    tbl_id <- dbQuoteIdentifier(con, table_name)
    col_id <- dbQuoteIdentifier(con, col_name)

    dbGetQuery(
      con,
      paste0(
        "SELECT ",
        dbQuoteString(con, table_name), " AS table_name, ",
        dbQuoteString(con, infer_feature_group(table_name)), " AS feature_group, ",
        dbQuoteString(con, "direct_column"), " AS storage_source, ",
        dbQuoteString(con, col_name), " AS tag_key, ",
        "CAST(", col_id, " AS VARCHAR) AS tag_value, ",
        "COUNT(*) AS n ",
        "FROM ", tbl_id, " ",
        "WHERE ", col_id, " IS NOT NULL ",
        "AND CAST(", col_id, " AS VARCHAR) <> '' ",
        "GROUP BY 5"
      )
    )
  })

  counts <- counts[vapply(counts, nrow, integer(1)) > 0]
  if (length(counts) == 0) {
    return(data.frame())
  }

  result <- do.call(rbind, counts)
  result$n <- as.numeric(result$n)
  result
}

get_all_tag_counts <- function(con, parse_limit) {
  tables <- get_tables(con)
  if (length(tables) == 0) {
    return(data.frame())
  }

  all_parts <- lapply(tables, function(tbl) {
    direct <- get_direct_tag_counts(con, tbl)
    other <- get_other_tags_counts(con, tbl, parse_limit)

    parts <- list(direct, other)
    parts <- parts[vapply(parts, nrow, integer(1)) > 0]

    if (length(parts) == 0) {
      return(data.frame())
    }
    do.call(rbind, parts)
  })

  all_parts <- all_parts[vapply(all_parts, nrow, integer(1)) > 0]
  if (length(all_parts) == 0) {
    return(data.frame())
  }

  out <- do.call(rbind, all_parts)
  out$n <- as.numeric(out$n)
  out
}

apply_filters <- function(df, table_filter, feature_filter, key_filter, value_filter, value_mode, min_count) {
  filtered <- df

  if (!is.null(table_filter) && !("All" %in% table_filter)) {
    filtered <- filtered[filtered$table_name %in% table_filter, , drop = FALSE]
  }

  if (!is.null(feature_filter) && !("All" %in% feature_filter)) {
    filtered <- filtered[filtered$feature_group %in% feature_filter, , drop = FALSE]
  }

  if (!is.null(key_filter) && key_filter != "All") {
    filtered <- filtered[filtered$tag_key == key_filter, , drop = FALSE]
  }

  value_term <- trimws(value_filter)
  if (nzchar(value_term) && nrow(filtered) > 0) {
    if (identical(value_mode, "Exact")) {
      keep <- tolower(filtered$tag_value) == tolower(value_term)
    } else {
      keep <- grepl(tolower(value_term), tolower(filtered$tag_value), fixed = TRUE)
    }
    filtered <- filtered[keep, , drop = FALSE]
  }

  filtered <- filtered[filtered$n >= as.numeric(min_count), , drop = FALSE]
  filtered
}

get_table_columns <- function(con, table_name) {
  cols <- dbGetQuery(con, paste0("PRAGMA table_info(", dbQuoteIdentifier(con, table_name), ")"))
  cols$name
}

get_feature_tables <- function(con) {
  all_tables <- dbGetQuery(
    con,
    "
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'main'
      AND table_type = 'BASE TABLE'
    ORDER BY table_name;
    "
  )

  keep <- vapply(all_tables$table_name, function(tbl) {
    cols <- dbGetQuery(con, paste0("PRAGMA table_info(", dbQuoteIdentifier(con, tbl), ")"))
    any(toupper(cols$name) == "WKT_GEOMETRY")
  }, logical(1))

  all_tables$table_name[keep]
}

get_direct_tag_columns <- function(con, table_name) {
  cols <- get_table_columns(con, table_name)
  excluded <- c("ogc_fid", "WKT_GEOMETRY", "osm_id", "osm_way_id", "z_order", "other_tags")
  setdiff(cols, excluded)
}

split_value_expression <- function(value_expression) {
  expr <- trimws(value_expression)
  if (!nzchar(expr)) {
    return(list(character(0)))
  }

  # Protect quoted literals so operator normalization does not rewrite them.
  quoted <- regmatches(expr, gregexpr('"[^\"]*"|\'[^\']*\'', expr, perl = TRUE))[[1]]
  placeholders <- character(0)
  if (length(quoted) > 0) {
    placeholders <- paste0("__Q", seq_along(quoted), "__")
    for (i in seq_along(quoted)) {
      expr <- sub(quoted[i], placeholders[i], expr, fixed = TRUE)
    }
  }

  # Support both word operators (AND/OR) and symbolic operators (&, ||).
  expr <- gsub("\\|\\|", " OR ", expr, perl = TRUE)
  expr <- gsub("(?i)\\bOR\\b", " OR ", expr, perl = TRUE)
  expr <- gsub("&", " AND ", expr, fixed = TRUE)
  expr <- gsub("(?i)\\bAND\\b", " AND ", expr, perl = TRUE)
  expr <- gsub("\\s+", " ", expr, perl = TRUE)
  expr <- trimws(expr)

  restore_quoted <- function(term) {
    restored <- term
    if (length(placeholders) > 0) {
      for (i in seq_along(placeholders)) {
        restored <- gsub(placeholders[i], quoted[i], restored, fixed = TRUE)
      }
    }

    # Strip matching outer quotes so quoted literals become normal search terms.
    if (grepl('^".*"$', restored)) {
      restored <- substr(restored, 2, nchar(restored) - 1)
    } else if (grepl("^'.*'$", restored)) {
      restored <- substr(restored, 2, nchar(restored) - 1)
    }
    restored
  }

  or_parts <- strsplit(expr, "\\s+OR\\s+", perl = TRUE)[[1]]
  lapply(or_parts, function(or_part) {
    and_parts <- strsplit(or_part, "\\s+AND\\s+", perl = TRUE)[[1]]
    and_parts <- trimws(and_parts)
    and_parts <- vapply(and_parts, restore_quoted, character(1))
    and_parts[nzchar(and_parts)]
  })
}

build_grouped_clause <- function(term_groups, term_builder) {
  or_clauses <- lapply(term_groups, function(and_terms) {
    if (length(and_terms) == 0) {
      return(NULL)
    }

    and_clauses <- vapply(and_terms, term_builder, character(1))
    and_clauses <- and_clauses[nzchar(and_clauses)]
    if (length(and_clauses) == 0) {
      return(NULL)
    }

    paste0("(", paste(and_clauses, collapse = " AND "), ")")
  })

  or_clauses <- unlist(or_clauses)
  or_clauses <- or_clauses[nzchar(or_clauses)]
  if (length(or_clauses) == 0) {
    return(NULL)
  }

  paste0("(", paste(or_clauses, collapse = " OR "), ")")
}

build_tag_clause <- function(con, table_name, source_type, direct_tag_col, other_tag_key, value_mode, tag_value) {
  cols <- get_table_columns(con, table_name)
  value <- trimws(tag_value)
  term_groups <- split_value_expression(value)

  if (identical(source_type, "Direct column")) {
    if (!(direct_tag_col %in% cols)) {
      return(NULL)
    }

    col_id <- dbQuoteIdentifier(con, direct_tag_col)
    if (!nzchar(value)) {
      return(paste0("CAST(", col_id, " AS VARCHAR) IS NOT NULL AND CAST(", col_id, " AS VARCHAR) <> ''"))
    }

    return(
      build_grouped_clause(term_groups, function(term) {
        if (identical(value_mode, "Exact")) {
          return(paste0("LOWER(CAST(", col_id, " AS VARCHAR)) = LOWER(", dbQuoteString(con, term), ")"))
        }

        paste0(
          "LOWER(CAST(", col_id, " AS VARCHAR)) LIKE LOWER(",
          dbQuoteString(con, paste0("%", term, "%")),
          ")"
        )
      })
    )
  }

  if (!("other_tags" %in% cols)) {
    return(NULL)
  }

  key <- trimws(other_tag_key)
  if (!nzchar(key)) {
    return(NULL)
  }

  other_tags_id <- dbQuoteIdentifier(con, "other_tags")

  if (!nzchar(value)) {
    pattern <- paste0('%"', key, '"=>"%')
    return(
      paste0(
        "LOWER(CAST(", other_tags_id, " AS VARCHAR)) LIKE LOWER(",
        dbQuoteString(con, pattern),
        ")"
      )
    )
  }

  build_grouped_clause(term_groups, function(term) {
    escaped_term <- gsub('"', '\\\\"', term)
    if (identical(value_mode, "Exact")) {
      pattern <- paste0('%"', key, '"=>"', escaped_term, '"%')
    } else {
      pattern <- paste0('%"', key, '"=>"%', escaped_term, '%"%')
    }

    paste0(
      "LOWER(CAST(", other_tags_id, " AS VARCHAR)) LIKE LOWER(",
      dbQuoteString(con, pattern),
      ")"
    )
  })
}

build_any_term_clause <- function(con, table_name, term, value_mode) {
  cols <- get_table_columns(con, table_name)
  direct_cols <- get_direct_tag_columns(con, table_name)

  direct_clauses <- lapply(direct_cols, function(col_name) {
    col_id <- dbQuoteIdentifier(con, col_name)
    if (identical(value_mode, "Exact")) {
      return(paste0("LOWER(CAST(", col_id, " AS VARCHAR)) = LOWER(", dbQuoteString(con, term), ")"))
    }

    paste0(
      "LOWER(CAST(", col_id, " AS VARCHAR)) LIKE LOWER(",
      dbQuoteString(con, paste0("%", term, "%")),
      ")"
    )
  })

  other_clause <- NULL
  if ("other_tags" %in% cols) {
    other_tags_id <- dbQuoteIdentifier(con, "other_tags")
    escaped_term <- gsub('"', '\\\\"', term)

    if (identical(value_mode, "Exact")) {
      pattern <- paste0('%=>"', escaped_term, '"%')
    } else {
      pattern <- paste0("%", escaped_term, "%")
    }

    other_clause <- paste0(
      "LOWER(CAST(", other_tags_id, " AS VARCHAR)) LIKE LOWER(",
      dbQuoteString(con, pattern),
      ")"
    )
  }

  parts <- c(unlist(direct_clauses), other_clause)
  parts <- parts[!vapply(parts, is.null, logical(1))]
  if (length(parts) == 0) {
    return("")
  }

  paste0("(", paste(parts, collapse = " OR "), ")")
}

build_any_clause <- function(con, table_name, value_mode, tag_value) {
  value <- trimws(tag_value)
  cols <- get_table_columns(con, table_name)

  if (!nzchar(value)) {
    direct_cols <- get_direct_tag_columns(con, table_name)
    direct_clauses <- lapply(direct_cols, function(col_name) {
      col_id <- dbQuoteIdentifier(con, col_name)
      paste0("CAST(", col_id, " AS VARCHAR) IS NOT NULL AND CAST(", col_id, " AS VARCHAR) <> ''")
    })

    other_clause <- NULL
    if ("other_tags" %in% cols) {
      other_tags_id <- dbQuoteIdentifier(con, "other_tags")
      other_clause <- paste0("CAST(", other_tags_id, " AS VARCHAR) IS NOT NULL AND CAST(", other_tags_id, " AS VARCHAR) <> ''")
    }

    clauses <- c(unlist(direct_clauses), other_clause)
    clauses <- clauses[!vapply(clauses, is.null, logical(1))]
    if (length(clauses) == 0) {
      return(NULL)
    }

    return(paste0("(", paste(clauses, collapse = " OR "), ")"))
  }

  term_groups <- split_value_expression(value)
  clauses <- build_grouped_clause(term_groups, function(term) {
    build_any_term_clause(con, table_name, term, value_mode)
  })

  if (is.null(clauses) || !nzchar(clauses)) {
    return(NULL)
  }

  clauses
}

count_layer_rows <- function(con, table_name, where_clause = NULL) {
  tbl_id <- dbQuoteIdentifier(con, table_name)
  sql <- paste0("SELECT COUNT(*) AS n FROM ", tbl_id)

  if (!is.null(where_clause) && nzchar(where_clause)) {
    sql <- paste0(sql, " WHERE ", where_clause)
  }

  sql <- paste0(sql, ";")
  dbGetQuery(con, sql)$n[[1]]
}

validate_integer_range <- function(value, minimum, maximum, label) {
  if (
    length(value) != 1 ||
      is.na(value) ||
      !is.finite(value) ||
      value != floor(value) ||
      value < minimum ||
      value > maximum
  ) {
    stop(label, " must be a whole number from ", minimum, " through ", maximum, ".")
  }

  as.integer(value)
}

read_layer_data <- function(con, table_name, max_rows, where_clause = NULL) {
  tbl_id <- dbQuoteIdentifier(con, table_name)
  sql <- paste0("SELECT * FROM ", tbl_id)

  if (!is.null(where_clause) && nzchar(where_clause)) {
    sql <- paste0(sql, " WHERE ", where_clause)
  }

  sql <- paste0(sql, " LIMIT ", as.integer(max_rows), ";")
  dbGetQuery(con, sql)
}

read_layer_data_all <- function(con, table_name, where_clause = NULL) {
  tbl_id <- dbQuoteIdentifier(con, table_name)
  sql <- paste0("SELECT * FROM ", tbl_id)

  if (!is.null(where_clause) && nzchar(where_clause)) {
    sql <- paste0(sql, " WHERE ", where_clause)
  }

  sql <- paste0(sql, ";")
  dbGetQuery(con, sql)
}

with_hover_info <- function(control, help_text) {
  tags$div(title = help_text, control)
}

build_feature_map <- function(sf_obj) {
  base_map <- leaflet() %>%
    addProviderTiles(providers$OpenStreetMap.Mapnik)

  if (nrow(sf_obj) == 0) {
    return(base_map)
  }

  geom_types <- as.character(st_geometry_type(sf_obj))
  supported_types <- c(
    "POINT", "MULTIPOINT",
    "LINESTRING", "MULTILINESTRING",
    "POLYGON", "MULTIPOLYGON"
  )
  unsupported_types <- unique(geom_types[is.na(geom_types) | !(geom_types %in% supported_types)])
  if (length(unsupported_types) > 0) {
    stop(
      "Unsupported or missing geometry type: ",
      paste(ifelse(is.na(unsupported_types), "NA", unsupported_types), collapse = ", ")
    )
  }

  label_col <- if ("name" %in% names(sf_obj)) "name" else if ("osm_id" %in% names(sf_obj)) "osm_id" else names(sf_obj)[1]
  label_values <- as.character(sf_obj[[label_col]])
  point_rows <- geom_types %in% c("POINT", "MULTIPOINT")
  line_rows <- geom_types %in% c("LINESTRING", "MULTILINESTRING")
  polygon_rows <- geom_types %in% c("POLYGON", "MULTIPOLYGON")

  if (any(point_rows)) {
    base_map <- addCircleMarkers(
      base_map,
      data = sf_obj[point_rows, , drop = FALSE],
      radius = 4,
      stroke = FALSE,
      fillOpacity = 0.7,
      label = label_values[point_rows]
    )
  }
  if (any(line_rows)) {
    base_map <- addPolylines(
      base_map,
      data = sf_obj[line_rows, , drop = FALSE],
      weight = 2,
      color = "#1b9e77",
      label = label_values[line_rows]
    )
  }
  if (any(polygon_rows)) {
    base_map <- addPolygons(
      base_map,
      data = sf_obj[polygon_rows, , drop = FALSE],
      weight = 1,
      color = "#2c7fb8",
      fillOpacity = 0.4,
      label = label_values[polygon_rows]
    )
  }

  base_map
}

ui <- fluidPage(
  titlePanel("Nicaragua OSM Viewer (DuckDB)"),
  tabsetPanel(
    tabPanel(
      "Map Explorer",
      sidebarLayout(
        sidebarPanel(
          with_hover_info(
            selectInput("table", "Layer", choices = character(0)),
            "Choose the feature table to query and display on the map."
          ),
          with_hover_info(
            selectInput("source_type", "Tag source", choices = c("Direct column", "other_tags", "Any"), selected = "Any"),
            "Pick where tag values are searched: direct columns, other_tags key/value pairs, or any source."
          ),
          conditionalPanel(
            condition = "input.source_type == 'Direct column'",
            with_hover_info(
              selectInput("direct_tag_col", "Tag column", choices = character(0)),
              "Select the direct attribute column used for filtering in Direct column mode."
            )
          ),
          conditionalPanel(
            condition = "input.source_type == 'other_tags'",
            with_hover_info(
              textInput("other_tag_key", "Tag key in other_tags", value = "amenity"),
              "Enter the key inside other_tags to filter, for example amenity, shop, or highway."
            )
          ),
          with_hover_info(
            selectInput("value_mode", "Value match", choices = c("Contains", "Exact"), selected = "Contains"),
            "Contains matches partial text; Exact matches the full value."
          ),
          with_hover_info(
            textInput("tag_value", "Tag value (AND/OR or &/||; \" or \" literals)", value = ""),
            "Filter expression. Use AND/OR or &/||. Quote literals like \"or\" when searching those words."
          ),
          with_hover_info(
            numericInput("max_rows", "Max features to draw", value = 5000, min = 100, max = 100000, step = 100),
            "Maximum number of matched features loaded to the map for display performance."
          ),
          with_hover_info(
            actionButton("reload", "Load layer"),
            "Apply the current filters and refresh map, stats, and preview."
          ),
          br(),
          br(),
          with_hover_info(
            downloadButton("download_gpkg", "Export filtered to GeoPackage"),
            "Export all matched features to a GeoPackage file using the current filters."
          )
        ),
        mainPanel(
          h4("Layer stats"),
          tableOutput("layer_stats"),
          leafletOutput("map", height = 650),
          h4("Preview (first 10 rows loaded)"),
          tableOutput("preview")
        )
      )
    ),
    tabPanel(
      "Tag Explorer",
      sidebarLayout(
        sidebarPanel(
          tags$div(
            title = "How many rows with other_tags are parsed per table. Higher values improve coverage but are slower.",
            numericInput("parse_limit", "Rows to parse in other_tags", value = 10000, min = 100, max = 500000, step = 100)
          ),
          tags$div(
            title = "Filter tags to selected source tables.",
            selectInput("table_filter", "Tables", choices = "All", selected = "All", multiple = TRUE)
          ),
          tags$div(
            title = "Filter tags by inferred feature group from table type.",
            selectInput("feature_filter", "Feature groups", choices = "All", selected = "All", multiple = TRUE)
          ),
          tags$div(
            title = "Restrict to one tag key.",
            selectInput("tag_key", "Tag key", choices = "All", selected = "All")
          ),
          tags$div(
            title = "Filter by tag value text.",
            textInput("tag_value_filter", "Tag value filter", value = "")
          ),
          tags$div(
            title = "Contains: partial match. Exact: full-value match.",
            selectInput("tag_value_mode", "Value match mode", choices = c("Contains", "Exact"), selected = "Contains")
          ),
          tags$div(
            title = "Keep rows with at least this many occurrences.",
            numericInput("min_count", "Minimum count", value = 1, min = 1, max = 1000000, step = 1)
          ),
          tags$div(
            title = "Recompute all tag summaries from nicaragua.duckdb.",
            actionButton("tag_refresh", "Refresh")
          )
        ),
        mainPanel(
          tabsetPanel(
            tabPanel(
              "Tag keys",
              p("All discovered tag keys across direct columns and parsed other_tags."),
              tableOutput("tag_keys")
            ),
            tabPanel(
              "Tag values",
              p("Tag key/value counts after filters."),
              tableOutput("tag_values")
            ),
            tabPanel(
              "Where tags reside",
              p("Shows the table and storage source (direct column vs other_tags) for matching tags."),
              tableOutput("tag_locations")
            ),
            tabPanel(
              "Raw filtered rows",
              p("Raw filtered rows for auditing individual tag-value entries."),
              tableOutput("tag_raw")
            )
          )
        )
      )
    )
  )
)

server <- function(input, output, session) {
  con <- dbConnect(duckdb(), dbdir = "./data/nicaragua.duckdb", read_only = TRUE)
  onStop(function() dbDisconnect(con, shutdown = TRUE))

  feature_tables <- get_feature_tables(con)
  if (length(feature_tables) == 0) {
    stop("No feature tables with WKT_GEOMETRY were found in ./data/nicaragua.duckdb")
  }

  updateSelectInput(session, "table", choices = feature_tables, selected = feature_tables[1])

  observeEvent(input$table, {
    req(input$table)

    direct_cols <- get_direct_tag_columns(con, input$table)
    if (length(direct_cols) == 0) {
      direct_cols <- ""
    }

    updateSelectInput(session, "direct_tag_col", choices = direct_cols, selected = direct_cols[1])
  }, ignoreInit = FALSE)

  layer_result <- eventReactive(input$reload, {
    req(input$table)
    max_rows <- validate_integer_range(input$max_rows, 100, 100000, "Map row limit")
    where_clause <- if (identical(input$source_type, "Any")) {
      build_any_clause(
        con = con,
        table_name = input$table,
        value_mode = input$value_mode,
        tag_value = input$tag_value
      )
    } else {
      build_tag_clause(
        con = con,
        table_name = input$table,
        source_type = input$source_type,
        direct_tag_col = input$direct_tag_col,
        other_tag_key = input$other_tag_key,
        value_mode = input$value_mode,
        tag_value = input$tag_value
      )
    }

    dat <- read_layer_data(
      con = con,
      table_name = input$table,
      max_rows = max_rows,
      where_clause = where_clause
    )

    total_rows <- count_layer_rows(con, input$table)
    matched_rows <- count_layer_rows(con, input$table, where_clause)
    loaded_rows <- nrow(dat)

    if (!"WKT_GEOMETRY" %in% names(dat)) {
      stop("Selected table does not include WKT_GEOMETRY")
    }

    tag_key_label <- if (identical(input$source_type, "Direct column")) {
      input$direct_tag_col
    } else if (identical(input$source_type, "other_tags")) {
      input$other_tag_key
    } else {
      "(any key)"
    }

    if (nrow(dat) == 0) {
      return(
        list(
          sf = st_sf(),
          raw = dat,
          where_clause = where_clause,
          stats = data.frame(
            layer = input$table,
            tag_source = input$source_type,
            tag_key = tag_key_label,
            total_rows = total_rows,
            matched_rows = matched_rows,
            loaded_rows = loaded_rows,
            stringsAsFactors = FALSE
          )
        )
      )
    }

    sf_obj <- st_as_sf(dat, wkt = "WKT_GEOMETRY", crs = 4326)
    list(
      sf = sf_obj,
      raw = dat,
      where_clause = where_clause,
      stats = data.frame(
        layer = input$table,
        tag_source = input$source_type,
        tag_key = tag_key_label,
        total_rows = total_rows,
        matched_rows = matched_rows,
        loaded_rows = loaded_rows,
        stringsAsFactors = FALSE
      )
    )
  }, ignoreInit = FALSE)

  output$layer_stats <- renderTable({
    layer_result()$stats
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$map <- renderLeaflet({
    build_feature_map(layer_result()$sf)
  })

  output$preview <- renderTable({
    obj <- layer_result()
    preview_df <- obj$raw
    if ("WKT_GEOMETRY" %in% names(preview_df)) {
      preview_df$WKT_GEOMETRY <- NULL
    }
    head(preview_df, 10)
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$download_gpkg <- downloadHandler(
    filename = function() {
      tbl <- gsub("[^A-Za-z0-9_]+", "_", input$table)
      paste0(tbl, "_filtered.gpkg")
    },
    content = function(file) {
      tryCatch({
        obj <- layer_result()
        where_clause <- obj$where_clause

        export_df <- read_layer_data_all(
          con = con,
          table_name = input$table,
          where_clause = where_clause
        )

        if (!"WKT_GEOMETRY" %in% names(export_df)) {
          stop("Selected table does not include WKT_GEOMETRY")
        }

        if (nrow(export_df) == 0) {
          stop("No features to export for the current filter.")
        }

        wkt_geometry <- trimws(as.character(export_df$WKT_GEOMETRY))
        if (!any(!is.na(wkt_geometry) & nzchar(wkt_geometry))) {
          stop("No geometry is available to export for the current filter.")
        }

        export_sf <- st_as_sf(export_df, wkt = "WKT_GEOMETRY", crs = 4326)
        geometry <- st_geometry(export_sf)
        has_geometry <- !is.na(geometry) & !st_is_empty(geometry)
        if (!any(has_geometry)) {
          stop("No geometry is available to export for the current filter.")
        }

        layer_name <- gsub("[^A-Za-z0-9_]+", "_", input$table)
        st_write(export_sf, dsn = file, layer = layer_name, delete_dsn = TRUE, quiet = TRUE)
      }, error = function(error) {
        showNotification(
          paste("GeoPackage export failed:", error$message),
          type = "error",
          duration = NULL
        )
        stop(error)
      })
    }
  )

  # Tag Explorer server logic
  all_tag_counts <- eventReactive(list(input$tag_refresh, input$parse_limit), {
    tryCatch({
      parse_limit <- validate_integer_range(
        input$parse_limit,
        100,
        500000,
        "other_tags parsing limit"
      )
      counts <- get_all_tag_counts(con, parse_limit)
      if (nrow(counts) == 0) {
        return(data.frame())
      }
      counts
    }, error = function(e) {
      showNotification(paste("Error loading tags:", e$message), type = "error", duration = 5)
      stop(e)
    })
  }, ignoreInit = TRUE)

  observeEvent(all_tag_counts(), {
    counts <- all_tag_counts()

    if (nrow(counts) == 0) {
      updateSelectInput(session, "table_filter", choices = "All", selected = "All")
      updateSelectInput(session, "feature_filter", choices = "All", selected = "All")
      updateSelectInput(session, "tag_key", choices = "All", selected = "All")
      return()
    }

    tables <- sort(unique(counts$table_name))
    features <- sort(unique(counts$feature_group))
    keys <- sort(unique(counts$tag_key))

    current_tables <- if (is.null(input$table_filter)) "All" else input$table_filter
    current_features <- if (is.null(input$feature_filter)) "All" else input$feature_filter
    current_keys <- if (is.null(input$tag_key)) "All" else input$tag_key

    updateSelectInput(session, "table_filter", choices = c("All", tables), selected = current_tables)
    updateSelectInput(session, "feature_filter", choices = c("All", features), selected = current_features)
    updateSelectInput(session, "tag_key", choices = c("All", keys), selected = current_keys)
  })

  filtered_tags <- reactive({
    counts <- all_tag_counts()
    if (nrow(counts) == 0) {
      return(data.frame())
    }

    apply_filters(
      counts,
      table_filter = input$table_filter,
      feature_filter = input$feature_filter,
      key_filter = input$tag_key,
      value_filter = input$tag_value_filter,
      value_mode = input$tag_value_mode,
      min_count = input$min_count
    )
  })

  output$tag_keys <- renderTable({
    filtered <- filtered_tags()
    if (nrow(filtered) == 0) {
      return(data.frame("No data" = character(0)))
    }

    key_summary <- aggregate(
      n ~ tag_key + storage_source,
      data = filtered,
      FUN = sum,
      drop = FALSE
    )
    key_summary <- key_summary[order(-key_summary$n, key_summary$tag_key), ]
    names(key_summary) <- c("Tag Key", "Storage Source", "Count")
    key_summary
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$tag_values <- renderTable({
    filtered <- filtered_tags()
    if (nrow(filtered) == 0) {
      return(data.frame("No data" = character(0)))
    }

    tag_values <- filtered[order(-filtered$n, filtered$tag_key, filtered$tag_value), ]
    names(tag_values) <- c("Table", "Feature Group", "Storage Source", "Tag Key", "Tag Value", "Count")
    tag_values
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$tag_locations <- renderTable({
    filtered <- filtered_tags()
    if (nrow(filtered) == 0) {
      return(data.frame("No data" = character(0)))
    }

    locations <- aggregate(
      n ~ tag_key + table_name + storage_source,
      data = filtered,
      FUN = sum,
      drop = FALSE
    )
    locations <- locations[order(-locations$n, locations$table_name, locations$tag_key), ]
    names(locations) <- c("Tag Key", "Table", "Storage Source", "Count")
    locations
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$tag_raw <- renderTable({
    filtered <- filtered_tags()
    if (nrow(filtered) == 0) {
      return(data.frame("No data" = character(0)))
    }

    filtered <- filtered[order(-filtered$n, filtered$table_name, filtered$tag_key, filtered$tag_value), ]
    names(filtered) <- c("Table", "Feature Group", "Storage Source", "Tag Key", "Tag Value", "Count")
    filtered
  }, striped = TRUE, bordered = TRUE, width = "100%")
}

shinyApp(ui, server)
