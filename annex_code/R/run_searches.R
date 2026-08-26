# ---------------------------------------------------------------------------
# run_searches.R — one-off runner for Module 02. Executes the full search
# matrix, caches per cell to data/raw/search/, then consolidates a
# harmonised ledger at data/derived/search_ledger.rds.
#
# Sources: OpenAlex, CORE. Crossref intentionally omitted per user
# direction 2026-08-12.
#
# Re-running is safe: cached cells are read from disk instead of re-fetched.
# To force a fresh fetch: `Rscript R/run_searches.R --force`.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(tibble); library(dplyr)
})

source(here::here("R", "config.R"))
source(here::here("R", "search_terms.R"))
source(here::here("R", "search.R"))

FORCE <- "--force" %in% commandArgs(trailingOnly = TRUE)

# Build the cell plan: per-country English/French; one pooled Arabic cell.
plan <- tibble::tribble(
  ~cell_id,             ~language, ~country,   ~geography_terms,
  "openalex_en_TN",     "en",      "Tunisia",  GEOGRAPHY_EN$Tunisia,
  "openalex_en_DZ",     "en",      "Algeria",  GEOGRAPHY_EN$Algeria,
  "openalex_en_MA",     "en",      "Morocco",  GEOGRAPHY_EN$Morocco,
  "openalex_en_LY",     "en",      "Libya",    GEOGRAPHY_EN$Libya,
  "openalex_en_EG",     "en",      "Egypt",    GEOGRAPHY_EN$Egypt,
  "openalex_en_REGION", "en",      "Region",   GEOGRAPHY_EN$Region,
  "openalex_fr_ALL",    "fr",      "ALL",      GEOGRAPHY_FR,
  "openalex_ar_ALL",    "ar",      "ALL",      GEOGRAPHY_AR,
  "core_en_TN",         "en",      "Tunisia",  GEOGRAPHY_EN$Tunisia,
  "core_en_DZ",         "en",      "Algeria",  GEOGRAPHY_EN$Algeria,
  "core_en_MA",         "en",      "Morocco",  GEOGRAPHY_EN$Morocco,
  "core_en_LY",         "en",      "Libya",    GEOGRAPHY_EN$Libya,
  "core_en_EG",         "en",      "Egypt",    GEOGRAPHY_EN$Egypt,
  "core_en_REGION",     "en",      "Region",   GEOGRAPHY_EN$Region,
  "core_fr_ALL",        "fr",      "ALL",      GEOGRAPHY_FR,
  "core_ar_ALL",        "ar",      "ALL",      GEOGRAPHY_AR
)

pick_terms <- function(lang, block) {
  switch(paste(block, lang, sep = "_"),
    conflict_en = CONFLICT_EN, wildlife_en = WILDLIFE_EN,
    conflict_fr = CONFLICT_FR, wildlife_fr = WILDLIFE_FR,
    conflict_ar = CONFLICT_AR, wildlife_ar = WILDLIFE_AR)
}

# Harmonise per-source raw returns into a common ledger row shape.
harmonise <- function(df, source, cell_id) {
  if (is.null(df) || NROW(df) == 0) return(NULL)
  if (source == "openalex") {
    tibble::tibble(
      cell_id          = cell_id,
      source           = "openalex",
      id               = df$id,
      doi              = df$doi,
      title            = df$title,
      abstract         = df$abstract,
      publication_year = df$publication_year,
      language         = df$language,
      is_oa            = df$is_oa,
      pdf_url          = df$pdf_url,
      relevance_score  = df$relevance_score,
      type             = df$type,
      source_container = df$source_display_name
    )
  } else if (source == "core") {
    tibble::tibble(
      cell_id          = cell_id,
      source           = "core",
      id               = df$id,
      doi              = df$doi,
      title            = df$title,
      abstract         = df$abstract,
      publication_year = df$publication_year,
      language         = NA_character_,
      is_oa            = !is.na(df$download_url) & nzchar(df$download_url),
      pdf_url          = df$download_url,
      relevance_score  = NA_real_,
      type             = NA_character_,
      source_container = df$data_providers,
      core_anchor      = if ("anchor" %in% names(df)) df$anchor else NA_character_
    )
  }
}

results <- list()
for (i in seq_len(NROW(plan))) {
  cell     <- plan[i, ]
  source   <- sub("_.*", "", cell$cell_id)
  message(sprintf("[%d/%d] %s  (language=%s, country=%s)",
                  i, NROW(plan), cell$cell_id, cell$language, cell$country))
  conflict <- pick_terms(cell$language, "conflict")
  wildlife <- pick_terms(cell$language, "wildlife")
  geo      <- cell$geography_terms[[1]]

  raw <- if (source == "openalex") {
    search_openalex(conflict, wildlife, geo,
                    language = cell$language, year_from = YEAR_FROM,
                    force = FORCE)
  } else if (source == "core") {
    # Anchored per-country queries — CORE's parser cannot handle compound
    # OR blocks (empirical: returned 7.6M hits for a 2-block AND query).
    # Only run for English cells (concept anchors are English phrases);
    # French/Arabic CORE is deferred until we have translated anchors.
    if (cell$language != "en") NULL else
      search_core_anchored(country_terms = geo,
                           year_from     = YEAR_FROM,
                           force         = FORCE)
  } else stop("unknown source: ", source)

  # core_anchored returns rows shaped like the old core search — reuse
  # the same harmoniser path.
  results[[cell$cell_id]] <- harmonise(raw, source, cell$cell_id)
  message(sprintf("     -> %d records", NROW(results[[cell$cell_id]])))
  Sys.sleep(0.5) # gentle spacing
}

ledger <- dplyr::bind_rows(results)
dir.create(here::here(DIR_DERIVED), showWarnings = FALSE, recursive = TRUE)
saveRDS(ledger, here::here(DIR_DERIVED, "search_ledger.rds"))

# Per-cell summary written next to the ledger for quick inspection.
per_cell <- ledger |>
  dplyr::count(cell_id, source, name = "n_records") |>
  dplyr::arrange(cell_id)
readr::write_csv(per_cell,
                 here::here(DIR_DERIVED, "search_per_cell_counts.csv"))

cat("\n=== per-cell counts ===\n")
print(per_cell, n = 100)
cat(sprintf("\nTotal raw ledger rows (pre-dedup): %d\n", NROW(ledger)))
cat(sprintf("Ledger written: %s\n",
            here::here(DIR_DERIVED, "search_ledger.rds")))

# Session-level OpenAlex credit spend, from the accumulator in search.R.
cat(sprintf("\nOpenAlex credits used this session: %d / %d cap (%.1f%%)\n",
            .oa_env$credits_used, .OPENALEX_CREDIT_CAP,
            100 * .oa_env$credits_used / .OPENALEX_CREDIT_CAP))
if (.oa_env$aborted) {
  cat("!! Credit guard tripped. Some OpenAlex cells returned NULL. Re-check plan.\n")
}
