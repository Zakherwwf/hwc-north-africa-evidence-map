# ---------------------------------------------------------------------------
# dedup.R — Module 03 deduplication.
#
# Two-pass strategy:
#   PASS 1 (DOI exact match on normalised DOI): collapses same-work
#          records indexed under different search cells or sources.
#   PASS 2 (title Jaro-Winkler >= 0.95 with year +/-1 block) on the
#          residue of records without DOI.
#
# When merging, we prefer the OpenAlex record as the canonical (richer
# metadata: abstract, is_oa, pdf_url, relevance_score) but preserve
# provenance from all merged sources in list-columns.
#
# Every merge is logged to logs/03_dedup_merges.jsonl so the record
# arithmetic reconciles for the flow diagram in Module 08.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(stringi)
  library(stringdist)
})

# ---- Normalisers ----------------------------------------------------------

normalize_doi <- function(x) {
  x <- stringi::stri_trim_both(x)
  x <- tolower(x)
  # Strip URL prefixes that Crossref/OpenAlex use inconsistently.
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x)
  x <- sub("^doi:\\s*",                     "", x)
  x[!nzchar(x)] <- NA_character_
  x
}

normalize_title <- function(x) {
  x <- stringi::stri_trans_general(x, "Any-Latin; Latin-ASCII; Lower")
  # Collapse whitespace, strip punctuation, drop leading articles.
  x <- gsub("[[:punct:]]+", " ", x)
  x <- gsub("\\s+", " ", x)
  x <- stringi::stri_trim_both(x)
  x <- sub("^(a|an|the) ", "", x)
  x[!nzchar(x)] <- NA_character_
  x
}

# ---- Merge policy ---------------------------------------------------------
# Given N rows for one work, pick the "best" as canonical and glue the
# provenance columns.

.pick_canonical <- function(rows) {
  # Prefer openalex, then non-empty abstract, then earliest source_container.
  ord <- order(
    rows$source != "openalex",             # openalex first
    is.na(rows$abstract) | !nzchar(rows$abstract),
    is.na(rows$title)    | !nzchar(rows$title)
  )
  rows[ord[1], , drop = FALSE]
}

.merge_group <- function(rows) {
  canon <- .pick_canonical(rows)
  canon$provenance_cells   <- list(unique(rows$cell_id))
  canon$provenance_sources <- list(unique(rows$source))
  canon$n_merged           <- NROW(rows)
  canon
}

# ---- PASS 1: DOI exact ----------------------------------------------------

dedup_by_doi <- function(ledger) {
  ledger <- ledger |>
    dplyr::mutate(doi_norm = normalize_doi(doi))

  has_doi <- ledger |> dplyr::filter(!is.na(doi_norm))
  no_doi  <- ledger |> dplyr::filter(is.na(doi_norm))

  # Split by doi_norm and merge.
  merged <- has_doi |>
    dplyr::group_by(doi_norm) |>
    dplyr::group_map(~ .merge_group(.x)) |>
    dplyr::bind_rows()

  # Log per-group merges where n_merged > 1.
  merged_multis <- merged |> dplyr::filter(n_merged > 1)
  .log_dedup(list(
    pass = "doi_exact",
    n_input        = NROW(has_doi),
    n_groups       = NROW(merged),
    n_multi_groups = NROW(merged_multis),
    rows_collapsed = sum(merged_multis$n_merged) - NROW(merged_multis)
  ))

  list(deduped = merged, residue = no_doi)
}

# ---- PASS 2: title + year -------------------------------------------------
# Per year block, cluster titles via Jaro-Winkler >=0.95 (single-linkage).

dedup_by_title_year <- function(residue, threshold = 0.95, year_tol = 1L) {

  # If no title or no year, we cannot cluster — pass through as-is,
  # each row becomes its own "cluster of 1".
  cluster_none <- residue |>
    dplyr::filter(is.na(publication_year) | is.na(title) | !nzchar(title))
  cluster_can  <- residue |>
    dplyr::filter(!is.na(publication_year), !is.na(title), nzchar(title)) |>
    dplyr::mutate(title_norm = normalize_title(title))

  # Blocks are 3-year windows: for each year Y, compare titles from
  # Y-1 .. Y+1. To avoid double-counting a pair we anchor on the earliest
  # year of each pair.
  years <- sort(unique(cluster_can$publication_year))
  cluster_can$cluster_id <- NA_integer_
  next_cluster <- 1L

  for (y in years) {
    rows_idx <- which(cluster_can$publication_year %in% (y - year_tol):(y + year_tol))
    if (length(rows_idx) < 2) next
    titles <- cluster_can$title_norm[rows_idx]
    # Jaro-Winkler DISTANCE (1 - similarity). Threshold 0.95 sim = 0.05 dist.
    d <- stringdist::stringdistmatrix(titles, titles, method = "jw", p = 0.1)
    close <- which(d <= (1 - threshold) & d > 0, arr.ind = TRUE)
    if (NROW(close) == 0) next
    # Union-find over indices within rows_idx.
    parent <- seq_along(rows_idx)
    find <- function(i) { while (parent[i] != i) { parent[i] <<- parent[parent[i]]; i <- parent[i] }; i }
    unite <- function(a, b) { pa <- find(a); pb <- find(b); if (pa != pb) parent[pa] <<- pb }
    for (k in seq_len(NROW(close))) if (close[k,1] < close[k,2]) unite(close[k,1], close[k,2])
    # Assign global cluster ids.
    for (i in seq_along(rows_idx)) {
      root_local <- find(i)
      global_idx <- rows_idx[root_local]
      existing <- cluster_can$cluster_id[global_idx]
      if (is.na(existing)) {
        cluster_can$cluster_id[global_idx] <- next_cluster
        next_cluster <- next_cluster + 1L
      }
      cluster_can$cluster_id[rows_idx[i]] <- cluster_can$cluster_id[global_idx]
    }
  }

  # Singletons get their own cluster ids too.
  cluster_can$cluster_id[is.na(cluster_can$cluster_id)] <-
    next_cluster:(next_cluster + sum(is.na(cluster_can$cluster_id)) - 1L)

  merged <- cluster_can |>
    dplyr::select(-title_norm) |>
    dplyr::group_by(cluster_id) |>
    dplyr::group_map(~ .merge_group(.x)) |>
    dplyr::bind_rows()
  # group_map drops the grouping column, so cluster_id is already absent.

  # Records we couldn't cluster (no year/title) pass through as singletons.
  singletons <- cluster_none |>
    dplyr::mutate(provenance_cells   = as.list(cell_id),
                  provenance_sources = as.list(source),
                  n_merged           = 1L)

  out <- dplyr::bind_rows(merged, singletons)

  merged_multis <- out |> dplyr::filter(n_merged > 1)
  .log_dedup(list(
    pass = "title_year_jw",
    threshold = threshold,
    year_tol  = year_tol,
    n_input        = NROW(residue),
    n_groups       = NROW(out),
    n_multi_groups = NROW(merged_multis),
    rows_collapsed = sum(merged_multis$n_merged) - NROW(merged_multis)
  ))
  out
}

# ---- Orchestrator ---------------------------------------------------------

run_dedup <- function(ledger_path = here::here(DIR_DERIVED, "search_ledger.rds"),
                      out_path    = here::here(DIR_DERIVED, "dedup_ledger.rds")) {
  ledger <- readRDS(ledger_path)
  message("Loaded ledger: ", NROW(ledger), " rows")

  p1 <- dedup_by_doi(ledger)
  message("Pass 1 (DOI exact): ", NROW(p1$deduped), " unique DOI groups; ",
          NROW(p1$residue), " no-DOI residue")

  p2 <- dedup_by_title_year(p1$residue)
  message("Pass 2 (title+year): ", NROW(p2), " residue clusters after title dedup")

  out <- dplyr::bind_rows(p1$deduped, p2)
  saveRDS(out, out_path)
  message("Wrote deduped ledger: ", out_path, "  (", NROW(out), " rows)")

  # Reconciliation math.
  .log_dedup(list(
    pass = "reconciliation",
    n_input_raw   = NROW(ledger),
    n_output_dedup = NROW(out),
    n_collapsed    = NROW(ledger) - NROW(out)
  ))
  invisible(out)
}

# ---- Log helper -----------------------------------------------------------

.log_dedup <- function(record) {
  dir.create(here::here(DIR_LOGS), showWarnings = FALSE, recursive = TRUE)
  path <- here::here(DIR_LOGS, "03_dedup.jsonl")
  cat(jsonlite::toJSON(c(record, list(when = format(Sys.time()))),
                       auto_unbox = TRUE, null = "null"), "\n",
      file = path, append = TRUE)
}
