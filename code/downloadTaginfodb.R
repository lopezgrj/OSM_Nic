library(DBI)
library(duckdb)

taginfo_url <- "https://taginfo.openstreetmap.org/download/taginfo-db.db.bz2"
raw_data_dir <- "./raw_data"
data_dir <- "./data"
compressed_path <- file.path(raw_data_dir, "taginfo-db.db.bz2")
uncompressed_path <- file.path(raw_data_dir, "taginfo-db.db")
duckdb_path <- file.path(data_dir, "taginfo-db.duckdb")

if (!dir.exists(raw_data_dir)) {
	dir.create(raw_data_dir, recursive = TRUE)
}

if (!dir.exists(data_dir)) {
	dir.create(data_dir, recursive = TRUE)
}

get_remote_content_length <- function(url) {
	if (Sys.which("curl") == "") {
		return(NA_real_)
	}

	headers <- tryCatch(
		system2("curl", c("-sIL", url), stdout = TRUE, stderr = TRUE),
		error = function(e) character(0)
	)

	if (length(headers) == 0) {
		return(NA_real_)
	}

	content_length_lines <- grep("^content-length:\\s*[0-9]+$", trimws(tolower(headers)), value = TRUE)
	if (length(content_length_lines) == 0) {
		return(NA_real_)
	}

	as.numeric(sub("^content-length:\\s*", "", tail(content_length_lines, 1)))
}

download_with_retries <- function(url, destfile, max_attempts = 5, timeout_seconds = 3600) {
	remote_size <- get_remote_content_length(url)
	old_timeout <- getOption("timeout")
	on.exit(options(timeout = old_timeout), add = TRUE)
	options(timeout = max(old_timeout, timeout_seconds))

	for (attempt in seq_len(max_attempts)) {
		if (file.exists(destfile)) {
			file.remove(destfile)
		}

		message(sprintf("Download attempt %d/%d", attempt, max_attempts))
		ok <- tryCatch({
			download.file(
				url,
				destfile = destfile,
				mode = "wb",
				method = "libcurl",
				quiet = FALSE
			)
			TRUE
		}, warning = function(w) {
			message("Download warning: ", conditionMessage(w))
			FALSE
		}, error = function(e) {
			message("Download error: ", conditionMessage(e))
			FALSE
		})

		if (!ok || !file.exists(destfile)) {
			next
		}

		local_size <- file.info(destfile)$size
		if (is.na(local_size) || local_size <= 0) {
			message("Downloaded file is empty or unreadable; retrying.")
			next
		}

		if (!is.na(remote_size) && local_size != remote_size) {
			message(sprintf(
				"Size mismatch (local: %s, remote: %s); retrying.",
				format(local_size, scientific = FALSE),
				format(remote_size, scientific = FALSE)
			))
			next
		}

		message("Download completed successfully.")
		return(invisible(TRUE))
	}

	stop("Failed to download a complete file after ", max_attempts, " attempts.")
}

decompress_bz2 <- function(src_path, dst_path) {
	if (file.exists(dst_path)) {
		file.remove(dst_path)
	}

	in_con <- bzfile(src_path, open = "rb")
	out_con <- file(dst_path, open = "wb")
	on.exit({
		if (exists("in_con") && isOpen(in_con)) {
			close(in_con)
		}
		if (exists("out_con") && isOpen(out_con)) {
			close(out_con)
		}
	}, add = TRUE)

	repeat {
		chunk <- readBin(in_con, what = "raw", n = 1024 * 1024)
		if (length(chunk) == 0) {
			break
		}
		writeBin(chunk, out_con)
	}
}

copy_sqlite_to_duckdb <- function(sqlite_path, duckdb_file) {
	con <- dbConnect(duckdb(), dbdir = duckdb_file)
	on.exit(if (dbIsValid(con)) dbDisconnect(con, shutdown = TRUE), add = TRUE)

	dbExecute(con, "INSTALL sqlite;")
	dbExecute(con, "LOAD sqlite;")
	dbExecute(
		con,
		paste0(
			"ATTACH ",
			dbQuoteString(con, sqlite_path),
			" AS taginfo_sqlite (TYPE sqlite);"
		)
	)
	on.exit(if (dbIsValid(con)) dbExecute(con, "DETACH taginfo_sqlite;"), add = TRUE)

	source_tables <- dbGetQuery(
		con,
		"
		SELECT table_name
		FROM information_schema.tables
		WHERE table_catalog = 'taginfo_sqlite'
		  AND table_schema = 'main'
		  AND table_type = 'BASE TABLE'
		ORDER BY table_name;
		"
	)

	if (nrow(source_tables) == 0) {
		stop("No source tables found in ", sqlite_path)
	}

	for (tbl_name in source_tables$table_name) {
		dst_tbl <- dbQuoteIdentifier(con, tbl_name)
		src_tbl <- dbQuoteIdentifier(con, tbl_name)
		dbExecute(
			con,
			paste0(
				"CREATE OR REPLACE TABLE ",
				dst_tbl,
				" AS SELECT * FROM taginfo_sqlite.",
				src_tbl,
				";"
			)
		)
	}
}

message("Downloading: ", taginfo_url)
download_with_retries(taginfo_url, compressed_path)

message("Decompressing to: ", uncompressed_path)
decompress_bz2(compressed_path, uncompressed_path)

message("Copying SQLite DB to DuckDB: ", duckdb_path)
copy_sqlite_to_duckdb(uncompressed_path, duckdb_path)

# Record the run timestamp for downstream checks and automation.
last_download_path <- file.path(raw_data_dir, "lastdownloadTagDB.txt")
last_download_text <- format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
writeLines(last_download_text, con = last_download_path)

message("Done.")
message("Compressed file: ", compressed_path)
message("Uncompressed file: ", uncompressed_path)
message("DuckDB file: ", duckdb_path)


