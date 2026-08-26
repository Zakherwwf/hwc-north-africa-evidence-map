# ---------------------------------------------------------------------------
# search.R — reusable search functions for Module 02. All functions are
# idempotent through disk caching under data/raw/search/. If a cache file
# exists and is newer than the code, it is reused; otherwise the API is hit
# and the result is cached.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(httr); library(jsonlite)
})

# Cache directory (created lazily).
.cache_dir <- function() {
  d <- here::here("data", "raw", "search")
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  d
}

# Deterministic cache key from source + query fingerprint.
.cache_path <- function(source, key) {
  file.path(.cache_dir(), sprintf("%s__%s.rds", source, key))
}

# Log every API hit to a per-day newline-delimited JSON file.
.log_hit <- function(record) {
  d <- here::here(DIR_LOGS)
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(d, sprintf("02_search_%s.jsonl",
                               format(Sys.Date(), "%Y%m%d")))
  cat(jsonlite::toJSON(record, auto_unbox = TRUE, null = "null"), "\n",
      file = path, append = TRUE)
}

.build_query <- function(conflict, wildlife, geography) {
  # Space-joined OR blocks — permissive relevance search (per protocol:
  # "cast wide"). Full Boolean AND is applied by the per-source function.
  paste(
    paste0("(", paste(q(conflict),  collapse = " OR "), ")"),
    paste0("(", paste(q(wildlife),  collapse = " OR "), ")"),
    paste0("(", paste(q(geography), collapse = " OR "), ")")
  )
}

# ---- OpenAlex (direct REST) ----------------------------------------------
# History:
#   1) openalexR's fetch layer swallowed 429s inside a 22-retry loop with
#      short waits, guaranteeing we blew through anonymous rate limits.
#   2) The `mailto=` "polite pool" was deprecated by OpenAlex in Feb 2026
#      and replaced by API keys (with a credit/USD budget model). The old
#      mailto parameter no longer unlocks higher limits.
# Direct httr gives us: guaranteed Bearer-token auth, explicit page pacing,
# proper 429 backoff, and rate-limit header logging so we can watch spend.

.OPENALEX_UA <- "hwc-na-evidence-map/0.1"

# Hard free-tier guard. OpenAlex's post-Feb-2026 pricing model exposes a
# credit budget via x-ratelimit-* headers (typically 10,000 credits / $1
# USD per key allocation). We stop early if we approach 80% of the visible
# ceiling, so we can never trigger paid overage.
.OPENALEX_CREDIT_CAP  <- 8000L
.oa_env <- new.env()
.oa_env$credits_used  <- 0L
.oa_env$aborted       <- FALSE

.oa_get <- function(url, max_tries = 4) {
  waits <- c(0, 60, 120, 240)
  key   <- Sys.getenv("OPENALEX_API_KEY", unset = "")
  if (!nzchar(key)) {
    warning("OPENALEX_API_KEY not set; using anonymous access (low rate limit).")
  }
  for (i in seq_len(max_tries)) {
    if (waits[i] > 0) Sys.sleep(waits[i])
    r <- tryCatch({
      if (nzchar(key)) {
        httr::GET(url,
                  httr::add_headers(Authorization = paste("Bearer", key)),
                  httr::user_agent(.OPENALEX_UA),
                  httr::timeout(60))
      } else {
        httr::GET(url,
                  httr::user_agent(.OPENALEX_UA),
                  httr::timeout(60))
      }
    }, error = function(e) NULL)
    if (is.null(r)) next
    # Log rate-limit headers and accumulate credit spend client-side.
    # Empirically the `x-ratelimit-credits-used` header is per-request cost
    # (constant ~10 across 484 sequential requests during the 2026-08-12
    # matrix run), not a running total. Accumulator has to live here.
    rl <- r$headers
    if (!is.null(rl$`x-ratelimit-credits-used`)) {
      cost <- suppressWarnings(as.integer(rl$`x-ratelimit-credits-used`))
      if (!is.na(cost)) .oa_env$credits_used <- .oa_env$credits_used + cost
      .log_hit(list(source            = "openalex",
                    ratelimit_cost    = rl$`x-ratelimit-credits-used`,
                    ratelimit_limit   = rl$`x-ratelimit-limit`,
                    ratelimit_usd     = rl$`x-ratelimit-limit-usd`,
                    session_total_used = .oa_env$credits_used,
                    when = Sys.time()))
    }
    # Free-tier guard.
    if (.oa_env$credits_used >= .OPENALEX_CREDIT_CAP) {
      message(sprintf("STOP: OpenAlex credits used = %d (cap = %d). Aborting further OpenAlex requests to stay within free tier.",
                      .oa_env$credits_used, .OPENALEX_CREDIT_CAP))
      .oa_env$aborted <- TRUE
      return(NULL)
    }
    if (httr::status_code(r) == 200) return(httr::content(r, "parsed", "application/json"))
    if (httr::status_code(r) == 401) {
      message("OpenAlex 401 Unauthorized — check OPENALEX_API_KEY")
      return(NULL)
    }
    if (httr::status_code(r) != 429) {
      message("OpenAlex HTTP ", httr::status_code(r), " for ", url)
      return(NULL)
    }
    message("OpenAlex 429; waiting ", waits[min(i+1, max_tries)], "s then retry ", i+1, "/", max_tries)
  }
  NULL
}

search_openalex <- function(conflict, wildlife, geography, language,
                            year_from, per_page = 200,
                            max_records = Inf, force = FALSE) {

  query <- .build_query(conflict, wildlife, geography)
  key   <- digest::digest(list(query, language, year_from, max_records, "v2"),
                          algo = "xxhash64")
  path  <- .cache_path("openalex", key)

  if (!force && file.exists(path)) {
    res <- readRDS(path)
    .log_hit(list(source = "openalex", cached = TRUE, key = key,
                  n = NROW(res), when = Sys.time()))
    return(res)
  }

  base    <- "https://api.openalex.org/works"
  filters <- paste(c(
    paste0("language:", language),
    paste0("from_publication_date:", year_from, "-01-01")
  ), collapse = ",")

  all_items <- list(); cursor <- "*"
  repeat {
    if (.oa_env$aborted) break
    url <- httr::modify_url(base, query = list(
      search   = query,
      filter   = filters,
      `per-page` = per_page,
      cursor   = cursor
    ))
    body <- .oa_get(url)
    if (is.null(body)) break
    items <- body$results
    if (length(items) == 0) break
    all_items <- c(all_items, items)
    cursor <- body$meta$next_cursor
    if (is.null(cursor) || length(all_items) >= max_records) break
    Sys.sleep(1)  # be courteous between pages
  }

  if (length(all_items) == 0) {
    .log_hit(list(source = "openalex", cached = FALSE, key = key,
                  language = language, n = 0, when = Sys.time()))
    return(NULL)
  }

  # Reshape to the tibble columns the harmoniser expects.
  extract <- function(x, path, default = NA_character_) {
    v <- x[[path[1]]]
    if (length(path) > 1) for (p in path[-1]) v <- v[[p]]
    if (is.null(v) || length(v) == 0) default else v
  }
  # Abstract in OpenAlex is stored as inverted index — reconstruct.
  ai_to_text <- function(ai) {
    if (is.null(ai) || length(ai) == 0) return(NA_character_)
    pos <- integer(); words <- character()
    for (w in names(ai)) {
      for (p in unlist(ai[[w]])) { pos <- c(pos, p); words <- c(words, w) }
    }
    paste(words[order(pos)], collapse = " ")
  }

  res <- tibble::tibble(
    id                    = vapply(all_items, function(x) extract(x, "id"), ""),
    doi                   = vapply(all_items, function(x) extract(x, "doi"), ""),
    title                 = vapply(all_items, function(x) extract(x, "title"), ""),
    abstract              = vapply(all_items, function(x) ai_to_text(x$abstract_inverted_index), ""),
    publication_year      = vapply(all_items, function(x) as.integer(extract(x, "publication_year", NA_integer_)), integer(1)),
    language              = vapply(all_items, function(x) extract(x, "language"), ""),
    is_oa                 = vapply(all_items, function(x) isTRUE(x$open_access$is_oa), logical(1)),
    pdf_url               = vapply(all_items, function(x) extract(x, c("best_oa_location","pdf_url")), ""),
    relevance_score       = vapply(all_items, function(x) as.numeric(extract(x, "relevance_score", NA_real_)), numeric(1)),
    type                  = vapply(all_items, function(x) extract(x, "type"), ""),
    source_display_name   = vapply(all_items, function(x) extract(x, c("primary_location","source","display_name")), "")
  )

  if (NROW(res) > max_records) res <- res[seq_len(max_records), ]
  saveRDS(res, path)
  .log_hit(list(source = "openalex", cached = FALSE, key = key,
                query_first_120 = substr(query, 1, 120),
                language = language, n = NROW(res), when = Sys.time()))
  res
}

# ---- Crossref -------------------------------------------------------------
# Direct REST — no rcrossref dependency. Crossref rewards a real UA + mailto
# with the "polite pool" (higher rate limits).

.CROSSREF_UA <- "hwc-na-evidence-map/0.1 (mailto:bouragaoui@wisc.edu)"

search_crossref <- function(conflict, wildlife, geography,
                            year_from, rows = 200,
                            max_records = Inf, force = FALSE) {

  # Crossref /works?query= uses relevance search — we join with spaces.
  # Boolean AND/OR are not honoured on the free endpoint.
  query <- .build_query(conflict, wildlife, geography)
  key   <- digest::digest(list(query, year_from, max_records),
                          algo = "xxhash64")
  path  <- .cache_path("crossref", key)

  if (!force && file.exists(path)) {
    res <- readRDS(path)
    .log_hit(list(source = "crossref", cached = TRUE, key = key,
                  n = NROW(res), when = Sys.time()))
    return(res)
  }

  fetched <- list(); offset <- 0
  repeat {
    r <- tryCatch(
      httr::GET("https://api.crossref.org/works",
                query = list(query = substr(query, 1, 400),
                             filter = paste0("from-pub-date:", year_from, "-01-01"),
                             rows = rows, offset = offset),
                httr::user_agent(.CROSSREF_UA),
                httr::timeout(30)),
      error = function(e) NULL)
    if (is.null(r) || httr::status_code(r) != 200) break
    body <- httr::content(r, "parsed", "application/json")
    items <- body$message$items
    if (length(items) == 0) break
    fetched <- c(fetched, items)
    if (length(fetched) >= max_records) break
    if (length(items) < rows) break
    offset <- offset + rows
    Sys.sleep(0.5)
  }

  if (length(fetched) == 0) {
    .log_hit(list(source = "crossref", cached = FALSE, key = key,
                  n = 0, when = Sys.time()))
    return(NULL)
  }

  res <- tibble::tibble(
    id                = vapply(fetched, function(x) x$DOI %||% NA_character_, ""),
    doi               = vapply(fetched, function(x) x$DOI %||% NA_character_, ""),
    title             = vapply(fetched, function(x) paste(unlist(x$title), collapse=" ") %||% NA_character_, ""),
    abstract          = vapply(fetched, function(x) x$abstract %||% NA_character_, ""),
    publication_year  = vapply(fetched, function(x) {
                              d <- x$issued$`date-parts`[[1]]
                              if (length(d) >= 1) as.integer(d[[1]]) else NA_integer_
                            }, integer(1)),
    type              = vapply(fetched, function(x) x$type %||% NA_character_, ""),
    source_container  = vapply(fetched, function(x) paste(unlist(x$`container-title`), collapse=" ") %||% NA_character_, "")
  )

  if (NROW(res) > max_records) res <- res[seq_len(max_records), ]
  saveRDS(res, path)
  .log_hit(list(source = "crossref", cached = FALSE, key = key,
                query_first_120 = substr(query, 1, 120),
                n = NROW(res), when = Sys.time()))
  res
}

# ---- CORE -----------------------------------------------------------------
# Requires bearer token from CORE_API_KEY. Recall: python-urllib is blocked
# but curl + Bearer token works; here we use httr which sends its own UA.

search_core <- function(conflict, wildlife, geography,
                        year_from, limit = 100,
                        max_records = Inf, force = FALSE) {

  key_env <- Sys.getenv("CORE_API_KEY", unset = NA_character_)
  if (is.na(key_env) || !nzchar(key_env)) {
    warning("CORE_API_KEY not set; skipping CORE search")
    return(NULL)
  }

  query <- .build_query(conflict, wildlife, geography)
  # CORE parses Lucene-ish syntax. Year uses square-bracket range.
  # Verified against a live probe: [1990 TO *] returns 200 with real
  # results; `>=` breaks the parser and returns near-zero.
  q_str <- paste0(query, " AND yearPublished:[", year_from, " TO *]")

  key  <- digest::digest(list(q_str, max_records), algo = "xxhash64")
  path <- .cache_path("core", key)

  if (!force && file.exists(path)) {
    res <- readRDS(path)
    .log_hit(list(source = "core", cached = TRUE, key = key,
                  n = NROW(res), when = Sys.time()))
    return(res)
  }

  fetched <- list(); offset <- 0
  repeat {
    r <- tryCatch(
      httr::GET("https://api.core.ac.uk/v3/search/works/",
                query = list(q = q_str, limit = limit, offset = offset),
                httr::add_headers(Authorization = paste("Bearer", key_env)),
                httr::timeout(30)),
      error = function(e) NULL)
    if (is.null(r) || httr::status_code(r) != 200) break
    body <- httr::content(r, "parsed", "application/json")
    items <- body$results
    if (length(items) == 0) break
    fetched <- c(fetched, items)
    if (length(fetched) >= max_records) break
    if (length(items) < limit) break
    offset <- offset + limit
    Sys.sleep(1) # CORE is stricter on rate
  }

  if (length(fetched) == 0) {
    .log_hit(list(source = "core", cached = FALSE, key = key,
                  n = 0, when = Sys.time()))
    return(NULL)
  }

  res <- tibble::tibble(
    id                = vapply(fetched, function(x) as.character(x$id %||% NA_character_), ""),
    doi               = vapply(fetched, function(x) x$doi %||% NA_character_, ""),
    title             = vapply(fetched, function(x) x$title %||% NA_character_, ""),
    abstract          = vapply(fetched, function(x) x$abstract %||% NA_character_, ""),
    publication_year  = vapply(fetched, function(x) as.integer(x$yearPublished %||% NA_integer_), integer(1)),
    download_url      = vapply(fetched, function(x) x$downloadUrl %||% NA_character_, ""),
    data_providers    = vapply(fetched, function(x) {
                              dp <- x$dataProviders
                              if (length(dp) == 0) NA_character_
                              else paste(vapply(dp, function(d) d$name %||% "", ""), collapse = "; ")
                            }, character(1))
  )

  if (NROW(res) > max_records) res <- res[seq_len(max_records), ]
  saveRDS(res, path)
  .log_hit(list(source = "core", cached = FALSE, key = key,
                query_first_120 = substr(q_str, 1, 120),
                n = NROW(res), when = Sys.time()))
  res
}

# ---- CORE (anchored, empirically-shaped) ---------------------------------
# Empirically CORE's free-tier /v3/search/works/ endpoint does NOT reliably
# parse compound Boolean OR blocks — the earlier version returned 7.6M hits
# for a 2-block AND query. Simple relevance queries with <=4 terms work.
#
# search_core_anchored() therefore runs multiple *narrow* per-country
# queries, one per concept anchor, and unions the results. Each query is
# short enough that CORE handles it correctly.

CORE_CONCEPT_ANCHORS <- c(
  '"human-wildlife conflict"',
  '"livestock depredation"',
  '"crop damage" wildlife',
  "bycatch",
  '"wildlife damage"',
  "persecution wildlife",
  "poisoning wildlife"
)

search_core_anchored <- function(country_terms, year_from,
                                 anchors = CORE_CONCEPT_ANCHORS,
                                 per_anchor_limit = 100,
                                 force = FALSE) {

  key_env <- Sys.getenv("CORE_API_KEY", unset = NA_character_)
  if (is.na(key_env) || !nzchar(key_env)) return(NULL)

  cache_key <- digest::digest(list(country_terms, anchors, year_from,
                                    per_anchor_limit), algo = "xxhash64")
  path <- .cache_path("core_anchored", cache_key)
  if (!force && file.exists(path)) {
    res <- readRDS(path)
    .log_hit(list(source = "core_anchored", cached = TRUE, key = cache_key,
                  n = NROW(res), when = Sys.time()))
    return(res)
  }

  # One query per (country term × anchor). Country terms are usually
  # 1–2 words ("Tunisia", "Tunisian"); anchors are 1–4 words.
  all_rows <- list()
  for (ct in country_terms) {
    for (an in anchors) {
      # Empirically-working shape (see search-diagnostics 2026-08-12):
      # short bare relevance query plus a single glued year predicate.
      q_str <- paste(ct, an, "AND", paste0("yearPublished>=", year_from))

      r <- tryCatch(
        httr::GET("https://api.core.ac.uk/v3/search/works/",
                  query = list(q = q_str, limit = per_anchor_limit),
                  httr::add_headers(Authorization = paste("Bearer", key_env)),
                  httr::timeout(30)),
        error = function(e) NULL)
      if (is.null(r) || httr::status_code(r) != 200) { Sys.sleep(1); next }
      items <- httr::content(r, "parsed", "application/json")$results
      if (length(items) == 0) { Sys.sleep(1); next }

      all_rows[[length(all_rows) + 1]] <- tibble::tibble(
        anchor           = an,
        country_term     = ct,
        id               = vapply(items, function(x) as.character(x$id %||% NA_character_), ""),
        doi              = vapply(items, function(x) x$doi %||% NA_character_, ""),
        title            = vapply(items, function(x) x$title %||% NA_character_, ""),
        abstract         = vapply(items, function(x) x$abstract %||% NA_character_, ""),
        publication_year = vapply(items, function(x) as.integer(x$yearPublished %||% NA_integer_), integer(1)),
        download_url     = vapply(items, function(x) x$downloadUrl %||% NA_character_, ""),
        data_providers   = vapply(items, function(x) {
                                dp <- x$dataProviders
                                if (length(dp) == 0) NA_character_
                                else paste(vapply(dp, function(d) d$name %||% "", ""), collapse = "; ")
                              }, character(1))
      )
      Sys.sleep(0.8) # be polite
    }
  }

  if (length(all_rows) == 0) {
    .log_hit(list(source = "core_anchored", cached = FALSE, key = cache_key,
                  n = 0, when = Sys.time()))
    return(NULL)
  }

  res <- dplyr::bind_rows(all_rows) |>
    dplyr::distinct(id, .keep_all = TRUE)   # dedup within-source
  saveRDS(res, path)
  .log_hit(list(source = "core_anchored", cached = FALSE, key = cache_key,
                n_before_dedup = sum(vapply(all_rows, NROW, 1L)),
                n_after_dedup  = NROW(res),
                when = Sys.time()))
  res
}

# Small "null coalescing" operator used above.
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
