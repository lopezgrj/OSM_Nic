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

build_where_clauses <- function(
    con,
    table_name,
    filter_col = NULL,
    filter_val = NULL,
    amenity_val = "All",
    highway_val = "All",
  leisure_val = "All",
  poi_types = character(0)
) {
  cols <- get_table_columns(con, table_name)
  clauses <- character(0)

  if (!is.null(filter_col) && nzchar(filter_col) && !is.null(filter_val) && nzchar(filter_val) && filter_col %in% cols) {
    col_id <- dbQuoteIdentifier(con, filter_col)
    val <- dbQuoteString(con, paste0("%", filter_val, "%"))
    clauses <- c(clauses, paste0("CAST(", col_id, " AS VARCHAR) ILIKE ", val))
  }

  add_equals_clause <- function(col_name, selected_val) {
    if (col_name %in% cols && !is.null(selected_val) && nzchar(selected_val) && selected_val != "All") {
      col_id <- dbQuoteIdentifier(con, col_name)
      val <- dbQuoteString(con, selected_val)
      paste0("CAST(", col_id, " AS VARCHAR) = ", val)
    } else {
      NULL
    }
  }

  clauses <- c(
    clauses,
    add_equals_clause("amenity", amenity_val),
    add_equals_clause("highway", highway_val),
    add_equals_clause("leisure", leisure_val)
  )

  if ("amenity" %in% cols && length(poi_types) > 0) {
    amenity_id <- dbQuoteIdentifier(con, "amenity")
    poi_sql_values <- vapply(poi_types, function(x) dbQuoteString(con, x), character(1))
    amenity_clause <- paste0(
      "CAST(",
      amenity_id,
      " AS VARCHAR) IN (",
      paste(poi_sql_values, collapse = ", "),
      ")"
    )

    if ("other_tags" %in% cols) {
      other_tags_id <- dbQuoteIdentifier(con, "other_tags")
      tag_checks <- character(0)

      if ("hospital" %in% poi_types) {
        tag_checks <- c(
          tag_checks,
          paste0("CAST(", other_tags_id, " AS VARCHAR) ILIKE '%\\\"amenity\\\"=>\\\"hospital\\\"%'"),
          paste0("CAST(", other_tags_id, " AS VARCHAR) ILIKE '%\\\"healthcare\\\"=>\\\"hospital\\\"%'")
        )
      }

      if ("pharmacy" %in% poi_types) {
        tag_checks <- c(
          tag_checks,
          paste0("CAST(", other_tags_id, " AS VARCHAR) ILIKE '%\\\"amenity\\\"=>\\\"pharmacy\\\"%'"),
          paste0("CAST(", other_tags_id, " AS VARCHAR) ILIKE '%\\\"shop\\\"=>\\\"chemist\\\"%'")
        )
      }

      if (length(tag_checks) > 0) {
        clauses <- c(clauses, paste0("(", amenity_clause, " OR ", paste(tag_checks, collapse = " OR "), ")"))
      } else {
        clauses <- c(clauses, amenity_clause)
      }
    } else {
      clauses <- c(clauses, amenity_clause)
    }
  } else if ("other_tags" %in% cols && length(poi_types) > 0) {
    other_tags_id <- dbQuoteIdentifier(con, "other_tags")
    tag_checks <- character(0)

    if ("hospital" %in% poi_types) {
      tag_checks <- c(
        tag_checks,
        paste0("CAST(", other_tags_id, " AS VARCHAR) ILIKE '%\\\"amenity\\\"=>\\\"hospital\\\"%'"),
        paste0("CAST(", other_tags_id, " AS VARCHAR) ILIKE '%\\\"healthcare\\\"=>\\\"hospital\\\"%'")
      )
    }

    if ("pharmacy" %in% poi_types) {
      tag_checks <- c(
        tag_checks,
        paste0("CAST(", other_tags_id, " AS VARCHAR) ILIKE '%\\\"amenity\\\"=>\\\"pharmacy\\\"%'"),
        paste0("CAST(", other_tags_id, " AS VARCHAR) ILIKE '%\\\"shop\\\"=>\\\"chemist\\\"%'")
      )
    }

    if (length(tag_checks) > 0) {
      clauses <- c(clauses, paste0("(", paste(tag_checks, collapse = " OR "), ")"))
    }
  }

  clauses[!vapply(clauses, is.null, logical(1))]
}

get_distinct_values <- function(con, table_name, column_name, max_values = 200) {
  cols <- get_table_columns(con, table_name)
  if (!(column_name %in% cols)) {
    return(character(0))
  }

  tbl_id <- dbQuoteIdentifier(con, table_name)
  col_id <- dbQuoteIdentifier(con, column_name)

  sql <- paste0(
    "SELECT DISTINCT CAST(", col_id, " AS VARCHAR) AS val ",
    "FROM ", tbl_id, " ",
    "WHERE ", col_id, " IS NOT NULL ",
    "AND CAST(", col_id, " AS VARCHAR) <> '' ",
    "ORDER BY val ",
    "LIMIT ", as.integer(max_values), ";"
  )

  vals <- dbGetQuery(con, sql)$val
  vals[!is.na(vals)]
}

count_layer_rows <- function(con, table_name, where_clauses = character(0)) {
  tbl_id <- dbQuoteIdentifier(con, table_name)
  sql <- paste0("SELECT COUNT(*) AS n FROM ", tbl_id)

  if (length(where_clauses) > 0) {
    sql <- paste0(sql, " WHERE ", paste(where_clauses, collapse = " AND "))
  }

  sql <- paste0(sql, ";")
  dbGetQuery(con, sql)$n[[1]]
}

read_layer_data <- function(
    con,
    table_name,
    max_rows,
    filter_col = NULL,
    filter_val = NULL,
    amenity_val = "All",
    highway_val = "All",
  leisure_val = "All",
  poi_types = character(0)
) {
  tbl_id <- dbQuoteIdentifier(con, table_name)
  sql <- paste0("SELECT * FROM ", tbl_id)

  where_clauses <- build_where_clauses(
    con,
    table_name,
    filter_col,
    filter_val,
    amenity_val,
    highway_val,
    leisure_val,
    poi_types
  )

  if (length(where_clauses) > 0) {
    sql <- paste0(sql, " WHERE ", paste(where_clauses, collapse = " AND "))
  }

  sql <- paste0(sql, " LIMIT ", as.integer(max_rows), ";")
  dbGetQuery(con, sql)
}

ui <- fluidPage(
  titlePanel("Nicaragua OSM Viewer (DuckDB)"),
  sidebarLayout(
    sidebarPanel(
      selectInput("table", "Layer", choices = character(0)),
      numericInput("max_rows", "Max features to draw", value = 5000, min = 100, max = 100000, step = 100),
      selectInput("filter_col", "Optional attribute filter column", choices = ""),
      textInput("filter_val", "Contains value", value = ""),
      selectInput("amenity_val", "Amenity", choices = "All", selected = "All"),
      selectInput("highway_val", "Highway", choices = "All", selected = "All"),
      selectInput("leisure_val", "Leisure", choices = "All", selected = "All"),
      checkboxGroupInput(
        "poi_types",
        "Quick POI filters",
        choices = c("Hospitals" = "hospital", "Pharmacies" = "pharmacy"),
        selected = character(0)
      ),
      actionButton("find_health", "Find Hospitals + Pharmacies"),
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

  observeEvent(input$find_health, {
    if ("points" %in% feature_tables) {
      updateSelectInput(session, "table", selected = "points")
    }
    updateCheckboxGroupInput(session, "poi_types", selected = c("hospital", "pharmacy"))
    updateSelectInput(session, "amenity_val", selected = "All")
  })

  observeEvent(input$table, {
    req(input$table)
    col_choices <- get_table_columns(con, input$table)
    updateSelectInput(session, "filter_col", choices = c("", col_choices), selected = "")

    amenity_choices <- c("All", get_distinct_values(con, input$table, "amenity"))
    highway_choices <- c("All", get_distinct_values(con, input$table, "highway"))
    leisure_choices <- c("All", get_distinct_values(con, input$table, "leisure"))

    updateSelectInput(session, "amenity_val", choices = amenity_choices, selected = "All")
    updateSelectInput(session, "highway_val", choices = highway_choices, selected = "All")
    updateSelectInput(session, "leisure_val", choices = leisure_choices, selected = "All")
  }, ignoreInit = FALSE)

  layer_result <- eventReactive(input$reload, {
    req(input$table)

    where_clauses <- build_where_clauses(
      con,
      input$table,
      input$filter_col,
      input$filter_val,
      input$amenity_val,
      input$highway_val,
      input$leisure_val,
      input$poi_types
    )

    dat <- read_layer_data(
      con,
      input$table,
      input$max_rows,
      input$filter_col,
      input$filter_val,
      input$amenity_val,
      input$highway_val,
      input$leisure_val,
      input$poi_types
    )

    total_rows <- count_layer_rows(con, input$table)
    matched_rows <- count_layer_rows(con, input$table, where_clauses)
    loaded_rows <- nrow(dat)

    if (!"WKT_GEOMETRY" %in% names(dat)) {
      stop("Selected table does not include WKT_GEOMETRY")
    }

    if (nrow(dat) == 0) {
      return(
        list(
          sf = st_sf(),
          raw = dat,
          stats = data.frame(
            layer = input$table,
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
