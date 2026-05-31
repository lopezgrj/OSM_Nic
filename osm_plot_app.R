library(shiny)
library(DBI)
library(duckdb)
library(sf)
library(leaflet)

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

  # Support both word operators (AND/OR) and symbolic operators (&, ||).
  expr <- gsub("\\|\\|", " OR ", expr, perl = TRUE)
  expr <- gsub("(?i)\\bOR\\b", " OR ", expr, perl = TRUE)
  expr <- gsub("&", " AND ", expr, fixed = TRUE)
  expr <- gsub("(?i)\\bAND\\b", " AND ", expr, perl = TRUE)
  expr <- gsub("\\s+", " ", expr, perl = TRUE)
  expr <- trimws(expr)

  or_parts <- strsplit(expr, "\\s+OR\\s+", perl = TRUE)[[1]]
  lapply(or_parts, function(or_part) {
    and_parts <- strsplit(or_part, "\\s+AND\\s+", perl = TRUE)[[1]]
    and_parts <- trimws(and_parts)
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

read_layer_data <- function(con, table_name, max_rows, where_clause = NULL) {
  tbl_id <- dbQuoteIdentifier(con, table_name)
  sql <- paste0("SELECT * FROM ", tbl_id)

  if (!is.null(where_clause) && nzchar(where_clause)) {
    sql <- paste0(sql, " WHERE ", where_clause)
  }

  sql <- paste0(sql, " LIMIT ", as.integer(max_rows), ";")
  dbGetQuery(con, sql)
}

ui <- fluidPage(
  titlePanel("Nicaragua OSM Viewer (DuckDB)"),
  sidebarLayout(
    sidebarPanel(
      selectInput("table", "Layer", choices = character(0)),
      selectInput("source_type", "Tag source", choices = c("Direct column", "other_tags", "Any"), selected = "Any"),
      conditionalPanel(
        condition = "input.source_type == 'Direct column'",
        selectInput("direct_tag_col", "Tag column", choices = character(0))
      ),
      conditionalPanel(
        condition = "input.source_type == 'other_tags'",
        textInput("other_tag_key", "Tag key in other_tags", value = "amenity")
      ),
      selectInput("value_mode", "Value match", choices = c("Contains", "Exact"), selected = "Contains"),
      textInput("tag_value", "Tag value (supports AND/OR or &/||)", value = ""),
      numericInput("max_rows", "Max features to draw", value = 5000, min = 100, max = 100000, step = 100),
      actionButton("reload", "Load layer")
    ),
    mainPanel(
      h4("Layer stats"),
      tableOutput("layer_stats"),
      leafletOutput("map", height = 650),
      h4("Preview (first 10 rows loaded)"),
      tableOutput("preview")
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
      max_rows = input$max_rows,
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
    obj <- layer_result()
    sf_obj <- obj$sf

    if (nrow(sf_obj) == 0) {
      return(
        leaflet() %>%
          addProviderTiles(providers$CartoDB.Positron)
      )
    }

    geom_types <- unique(as.character(st_geometry_type(sf_obj)))

    base_map <- leaflet(sf_obj) %>%
      addProviderTiles(providers$CartoDB.Positron)

    label_col <- if ("name" %in% names(sf_obj)) "name" else if ("osm_id" %in% names(sf_obj)) "osm_id" else names(sf_obj)[1]
    label_values <- as.character(sf_obj[[label_col]])

    if (all(geom_types %in% c("POINT", "MULTIPOINT"))) {
      base_map %>%
        addCircleMarkers(
          radius = 4,
          stroke = FALSE,
          fillOpacity = 0.7,
          label = label_values
        )
    } else if (all(geom_types %in% c("LINESTRING", "MULTILINESTRING"))) {
      base_map %>%
        addPolylines(weight = 2, color = "#1b9e77", label = label_values)
    } else {
      base_map %>%
        addPolygons(weight = 1, color = "#2c7fb8", fillOpacity = 0.4, label = label_values)
    }
  })

  output$preview <- renderTable({
    obj <- layer_result()
    preview_df <- obj$raw
    if ("WKT_GEOMETRY" %in% names(preview_df)) {
      preview_df$WKT_GEOMETRY <- NULL
    }
    head(preview_df, 10)
  }, striped = TRUE, bordered = TRUE, width = "100%")
}

shinyApp(ui, server)
