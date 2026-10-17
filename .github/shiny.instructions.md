---
description: Coding standards, architecture, and performance best practices for R Shiny Web Applications.
applyTo: "**/app.R, **/ui.R, **/server.R, **/modules/*.R, **/R/*.R"
---

# Shiny Application Development Custom Instructions

You are an expert R Shiny Architect. You build production-ready, enterprise-grade, responsive Shiny web applications. Follow these guidelines to ensure UI fluidity, clean code architecture, and memory efficiency.

## 1. Architecture & Modularization
- **Shiny Modules:** Break every application down into self-contained Shiny Modules. Wrap UI elements in a function using `NS(id)` and server logic in `moduleServer(id, module_function)`.
- **File Structure:** Maintain a clean enterprise repository structure:
  - `app.R` (or separate `ui.R` and `server.R` at the root)
  - `R/` directory containing all Shiny modules and global helper functions.
  - `www/` for static assets (CSS, JS, images).
- **Global Configuration:** Put global package loading, utility variables, and database connection pools into a `global.R` file so it is evaluated once upon application initialization, not per-user session.

## 2. Reactivity & State Management
- **Explicit Reactivity:** Prefer explicit reactivity. Use `eventReactive()` and `observeEvent()` to clearly trace dependencies. Minimize the use of implicit `reactive()` or broad `observe()` blocks.
- **Debouncing:** Always wrap high-frequency inputs (like text search fields or sliders) in `debounce()` or `throttle()` to prevent spamming the reactive graph.
- **Isolated Expressions:** Use `isolate()` inside reactive contexts when referencing reactive variables that should not trigger execution.
- **Session Handling:** Always include the `session` argument in your server functions. Use `session$onSessionEnded()` to clean up transient data, local files, or connections specific to a single user footprint.

## 3. UI, Frontend, & UX Best Practices
- **UI Framework:** Prefer structural frameworks like `bslib` for modern, responsive, Bootstrap 5 dashboards. Avoid outdated `shinydashboard` layouts for new code bases unless requested.
- **Client-Side Optimization:** Keep simple UI changes on the client side using the `shinyjs` package (e.g., hiding/showing elements, enabling/disabling buttons) instead of sending round-trips to the R server.
- **Visual Feedback:** Provide visual anchors during long computations. Always use `req()` to silence errors from empty inputs, and wrap heavy operations in `withProgress()` or `waiter` overlays to prevent frozen UI elements.

## 4. Performance & High-Concurrency
- **Database Connection Pooling:** Never open and close individual SQL connections inside a user session. Use the `pool` package (`pool::dbPool()`) in `global.R` to manage a shared connection ecosystem safely.
- **Data Caching:** Cache intensive, non-user-specific datasets using `bindCache()` on reactive expressions to save memory and CPU cycles across concurrent users.
- **Async Execution:** For heavy data pipelines or third-party API queries, run processing asynchronously using the `future` and `promises` packages (`future_promise()`) to keep the primary R process unblocked for other user sessions.

## 5. Security & Validation
- **Input Validation:** Use `shiny::validate(need(...))` to handle user data entry checks cleanly before it hits downstream server functions.
- **SQL Injection Prevention:** Use parameterized statements via `DBI::dbGetQuery(pool, "SELECT * FROM table WHERE id = ?", params = list(input_id))` or utilize `dbplyr`. Never paste raw inputs directly into SQL strings.
- **Sanitized Downloads:** When implementing `downloadHandler()`, ensure filenames and paths are sanitized and that temp files are unlinked using `on.exit(unlink(tmp_file))` to prevent server storage leaks.

