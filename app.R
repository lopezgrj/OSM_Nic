if (interactive()) {
	options(shiny.launch.browser = TRUE)

	# RStudio Viewer can behave differently for some UI features and downloads.
	if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
		options(viewer = NULL)
	}
}

source("osm_plot_app.R")
