library(shiny)
library(DBI)
library(duckdb)

get_tables <- function(con) {
  dbGetQuery(
    con,
    "
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'main'
      AND table_type = 'BASE TABLE'
    ORDER BY table_name;
    "
  )$table_name
}

get_table_columns <- function(con, table_name) {
  dbGetQuery(
    con,
    paste0("PRAGMA table_info(", dbQuoteIdentifier(con, table_name), ")")
  )
}

get_table_sample <- function(con, table_name, sample_limit) {
  dbGetQuery(
    con,
    paste0(
      "SELECT * FROM ",
      dbQuoteIdentifier(con, table_name),
      " LIMIT ",
      as.integer(sample_limit),
      ";"
    )
  )
}

get_table_row_count <- function(con, table_name) {
  dbGetQuery(
    con,
    paste0("SELECT COUNT(*) AS n FROM ", dbQuoteIdentifier(con, table_name), ";")
  )$n[[1]]
}

get_schema_overview <- function(con) {
  dbGetQuery(
    con,
    "
    SELECT
      table_schema,
      table_name,
      table_type
    FROM information_schema.tables
    ORDER BY table_schema, table_name;
    "
  )
}

get_column_catalog <- function(con) {
  dbGetQuery(
    con,
    "
    SELECT
      table_schema,
      table_name,
      column_name,
      data_type,
      ordinal_position,
      is_nullable
    FROM information_schema.columns
    ORDER BY table_schema, table_name, ordinal_position;
    "
  )
}

ui <- fluidPage(
  titlePanel("OSM Nic Structure Explorer"),
  tabsetPanel(
    tabPanel(
      "Database overview",
      h4("Main schema tables"),
      tableOutput("table_overview")
    ),
    tabPanel(
      "Table explorer",
      sidebarLayout(
        sidebarPanel(
          tags$div(
            title = "Choose the table to inspect columns and preview rows.",
            selectInput("table", "Table", choices = character(0))
          ),
          tags$div(
            title = "Number of rows shown in the sample preview.",
            numericInput("sample_limit", "Sample rows", value = 25, min = 5, max = 500, step = 5)
          ),
          tags$div(
            title = "Reload table list and metadata from DuckDB.",
            actionButton("refresh", "Refresh")
          )
        ),
        mainPanel(
          h4("Columns"),
          tableOutput("schema"),
          h4("Sample rows"),
          tableOutput("sample")
        )
      )
    ),
    tabPanel(
      "Information schema",
      h4("All tables"),
      tableOutput("all_tables"),
      h4("All columns"),
      tableOutput("all_columns")
    )
  )
)

server <- function(input, output, session) {
  con <- dbConnect(duckdb(), dbdir = "./data/nicaragua.duckdb", read_only = TRUE)
  onStop(function() dbDisconnect(con, shutdown = TRUE))

  tables <- get_tables(con)
  if (length(tables) == 0) {
    stop("No tables found in ./data/nicaragua.duckdb")
  }

  updateSelectInput(session, "table", choices = tables, selected = tables[1])

  observeEvent(input$refresh, {
    refreshed_tables <- get_tables(con)
    if (length(refreshed_tables) == 0) {
      stop("No tables found in ./data/nicaragua.duckdb")
    }

    selected <- input$table
    if (is.null(selected) || !(selected %in% refreshed_tables)) {
      selected <- refreshed_tables[1]
    }

    updateSelectInput(session, "table", choices = refreshed_tables, selected = selected)
  }, ignoreInit = FALSE)

  output$table_overview <- renderTable({
    out <- lapply(tables, function(tbl) {
      cols <- get_table_columns(con, tbl)$name
      data.frame(
        table_name = tbl,
        row_count = get_table_row_count(con, tbl),
        num_columns = length(cols),
        has_wkt_geometry = "WKT_GEOMETRY" %in% cols,
        stringsAsFactors = FALSE
      )
    })
    do.call(rbind, out)
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$schema <- renderTable({
    req(input$table)
    get_table_columns(con, input$table)
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$sample <- renderTable({
    req(input$table)
    get_table_sample(con, input$table, input$sample_limit)
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$all_tables <- renderTable({
    get_schema_overview(con)
  }, striped = TRUE, bordered = TRUE, width = "100%")

  output$all_columns <- renderTable({
    get_column_catalog(con)
  }, striped = TRUE, bordered = TRUE, width = "100%")
}

shinyApp(ui, server)
