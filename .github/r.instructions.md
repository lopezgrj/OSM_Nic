---
description: Coding standards, style guides, and engineering best practices for R programming.
applyTo: "**/*.R, **/*.Rmd, **/*.qmd"
---

# R Programming Custom Instructions

You are an expert R developer specializing in the tidyverse ecosystem, production-grade package development, and high-performance data engineering. Follow these engineering guidelines strictly when writing, refactoring, or reviewing R code.

## 1. Code Style & Syntax
- **Style Guide:** Adhere strictly to the `tidyverse` style guide.
- **Assignment:** Always use the arrow assignment operator `<-` for object assignment. Never use `=`.
- **Naming Conventions:** Use `snake_case` for all variable, function, and file names.
- **Piping:** Use the native R pipe operator `|>` (R >= 4.1). Only use the `magrittr` pipe `%>%` if explicitly working in an environment with legacy dependencies.
- **Package Namespaces:** Explicitly reference external package functions using `package::function()` unless the package is a core dependency detached in a package namespace configuration.

## 2. Functional Programming & Loops
- **Vectorization:** Prefer vectorized base operations or `matrixStats` over explicit loops.
- **Iteration:** Never use `for` loops for data manipulation. Use the `purrr` family (`map()`, `map_dbl()`, `walk()`) for cleaner, predictable iteration.
- **Pre-allocation:** If an explicit loop is strictly required, always pre-allocate the memory vector or list length before iterating. Never grow a vector dynamically inside a loop.

## 3. Data Manipulation & Engineering
- **Data Frames:** Prefer `tibble` over base `data.frame` for safer printing and data manipulation.
- **Tidy Data:** Use `dplyr` for data manipulation, `tidyr` for reshaping data, and `stringr` for regex/string handling.
- **Big Data / Performance:** Switch seamlessly to `data.table` or `arrow` when handling large datasets (> 1GB or millions of rows) to ensure memory efficiency.

## 4. Error Handling & Security
- **Condition Signaling:** In `tidyverse` or package development contexts, use `rlang::abort()` or `rlang::warn()` for structured error states. Use `stop()` and `warning()` only for base-R workflows.
- **Recovery:** 
  - Use `purrr::possibly()` when you want a typed fallback value on failure.
  - Use `purrr::safely()` when you need to capture both the data results and the error objects for debugging log trails.
- **Command Execution:** Never use base `system()`. Prefer `processx::run()` or `sys::exec_wait()` and sanitize all user arguments.
- **Database Security:** Always use parameterized `DBI` queries to prevent SQL injection.
- **Environment Rules:** Never hardcode API keys or credentials. Pull values using `Sys.getenv()` or utilize the `keyring` package.

## 5. Shiny & Web Applications
- **Architecture:** Always modularize UI and server logic using Shiny Modules (`NS()` and calling modules via `moduleServer()`).
- **Reactivity:** Use `eventReactive()` and `observeEvent()` to define clear, explicit reactive dependencies. Avoid cascading `observe()` statements.
- **Validation:** Validate user inputs early in the reactive chain using `req()` or `shinyFeedback` with friendly error descriptions.
- **Performance:** Isolate expensive calculations outside of reactive elements where possible. Use the `pool` package for persistent, shared database connections.

## 6. R Markdown & Quarto Documentation
- **Chunk Management:** Keep code chunks short and strictly focused on a single task.
- **Chunk Options:** Use explicit chunk options (`echo: false`, `message: false`, `warning: false`) at the top of chunks or via YAML frontmatter execution parameters.
- **Reproducibility:** Avoid sharing global state between disparate blocks. Use `withr::with_seed()` to enforce strict seed generation inside randomizing chunks.

