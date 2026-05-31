library(shiny)
library(DBI)
library(duckdb)

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

get_table_columns <- function(con, table_name) {
	dbGetQuery(
		con,
		paste0("PRAGMA table_info(", dbQuoteIdentifier(con, table_name), ")")
	)
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
	cols <- get_table_columns(con, table_name)$name
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
	cols <- get_table_columns(con, table_name)$name
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

ui <- fluidPage(
	titlePanel("Nicaragua OSM Tag Explorer"),
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
				textInput("tag_value", "Tag value filter", value = "")
			),
			tags$div(
				title = "Contains: partial match. Exact: full-value match.",
				selectInput("value_mode", "Value match mode", choices = c("Contains", "Exact"), selected = "Contains")
			),
			tags$div(
				title = "Keep rows with at least this many occurrences.",
				numericInput("min_count", "Minimum count", value = 1, min = 1, max = 1000000, step = 1)
			),
			tags$div(
				title = "Recompute all tag summaries from nicaragua.duckdb.",
				actionButton("refresh", "Refresh")
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

server <- function(input, output, session) {
	con <- dbConnect(duckdb(), dbdir = "./data/nicaragua.duckdb", read_only = TRUE)
	onStop(function() dbDisconnect(con, shutdown = TRUE))

	all_tag_counts <- eventReactive(list(input$refresh, input$parse_limit), {
		counts <- get_all_tag_counts(con, input$parse_limit)
		if (nrow(counts) == 0) {
			return(data.frame())
		}
		counts
	}, ignoreInit = FALSE)

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

		current_tables <- input$table_filter
		current_features <- input$feature_filter
		current_key <- input$tag_key

		if (is.null(current_tables) || length(current_tables) == 0) {
			current_tables <- "All"
		}
		if (is.null(current_features) || length(current_features) == 0) {
			current_features <- "All"
		}
		if (is.null(current_key) || !(current_key %in% c("All", keys))) {
			current_key <- "All"
		}

		updateSelectInput(
			session,
			"table_filter",
			choices = c("All", tables),
			selected = if ("All" %in% current_tables) "All" else intersect(current_tables, tables)
		)

		updateSelectInput(
			session,
			"feature_filter",
			choices = c("All", features),
			selected = if ("All" %in% current_features) "All" else intersect(current_features, features)
		)

		updateSelectInput(session, "tag_key", choices = c("All", keys), selected = current_key)
	}, ignoreInit = FALSE)

	filtered_counts <- reactive({
		counts <- all_tag_counts()
		if (nrow(counts) == 0) {
			return(data.frame())
		}

		apply_filters(
			counts,
			table_filter = input$table_filter,
			feature_filter = input$feature_filter,
			key_filter = input$tag_key,
			value_filter = input$tag_value,
			value_mode = input$value_mode,
			min_count = input$min_count
		)
	})

	output$tag_keys <- renderTable({
		dat <- filtered_counts()
		if (nrow(dat) == 0) {
			return(data.frame(message = "No rows match current filters."))
		}

		key_counts <- aggregate(n ~ tag_key, data = dat, FUN = sum)
		value_counts <- aggregate(tag_value ~ tag_key, data = dat, function(x) length(unique(x)))
		names(value_counts)[2] <- "distinct_values"
		table_counts <- aggregate(table_name ~ tag_key, data = dat, function(x) length(unique(x)))
		names(table_counts)[2] <- "tables_present"

		out <- merge(key_counts, value_counts, by = "tag_key", all.x = TRUE)
		out <- merge(out, table_counts, by = "tag_key", all.x = TRUE)
		names(out)[2] <- "occurrences"

		out[order(-out$occurrences, out$tag_key), ]
	}, striped = TRUE, bordered = TRUE, width = "100%")

	output$tag_values <- renderTable({
		dat <- filtered_counts()
		if (nrow(dat) == 0) {
			return(data.frame(message = "No rows match current filters."))
		}

		out <- aggregate(n ~ tag_key + tag_value, data = dat, FUN = sum)
		out[order(-out$n, out$tag_key, out$tag_value), ]
	}, striped = TRUE, bordered = TRUE, width = "100%")

	output$tag_locations <- renderTable({
		dat <- filtered_counts()
		if (nrow(dat) == 0) {
			return(data.frame(message = "No rows match current filters."))
		}

		out <- aggregate(n ~ tag_key + table_name + feature_group + storage_source, data = dat, FUN = sum)
		out[order(-out$n, out$tag_key, out$table_name), ]
	}, striped = TRUE, bordered = TRUE, width = "100%")

	output$tag_raw <- renderTable({
		dat <- filtered_counts()
		if (nrow(dat) == 0) {
			return(data.frame(message = "No rows match current filters."))
		}

		dat[order(-dat$n, dat$tag_key, dat$table_name), c("table_name", "feature_group", "storage_source", "tag_key", "tag_value", "n")]
	}, striped = TRUE, bordered = TRUE, width = "100%")
}

shinyApp(ui, server)
