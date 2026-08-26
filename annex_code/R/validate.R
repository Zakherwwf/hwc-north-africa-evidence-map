# ---------------------------------------------------------------------------
# validate.R — Module 04a benchmark validation utilities.
#
# Provides:
#  * SYNERGY loader (reads <dataset>_ids.csv, expands via OpenAlex to get
#    title + abstract for each labelled record).
#  * Stratified sampler that preserves prevalence.
#  * Confusion-matrix metrics: sensitivity, specificity, precision, F1,
#    Cohen's kappa, MCC, Gwet's AC1.
#
# All fetch results are cached; metrics computation is pure and re-runs
# instantly from cached predictions.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr); library(httr); library(jsonlite)
})

.SYN_DIR <- function() here::here("data", "benchmarks", "synergy")

# Short, faithful paraphrase of each SYNERGY dataset's inclusion criteria.
# Full protocol validation would use the reviews' original criteria verbatim
# from their methods sections; these paraphrases capture the discriminative
# signal for a bounded-time proof of the ensemble+prompt framework.
SYNERGY_CRITERIA <- list(
  "Nagtegaal_2019" = paste(
    "Empirical study (any design) that examines the use, effects, or",
    "consequences of performance measurement or performance management",
    "instruments in the public sector (government, public administration,",
    "or public services). Exclude: pure theoretical/conceptual papers with",
    "no empirical component; private-sector-only studies; commentaries."
  ),
  "Bannach-Brown_2019" = paste(
    "Preclinical study using a non-human animal model to investigate",
    "depression, depressive-like behaviour, or antidepressant treatment.",
    "Exclude: purely human clinical studies; in vitro / molecular studies",
    "with no behavioural depression endpoint; reviews or commentaries."
  )
)

load_synergy_ids <- function(dataset_name) {
  path <- file.path(.SYN_DIR(), sprintf("%s_ids.csv", dataset_name))
  stopifnot(file.exists(path))
  raw <- readr::read_csv(path, show_col_types = FALSE)
  n_in <- NROW(raw)
  out <- raw |>
    dplyr::mutate(
      record_id = openalex_id,
      label     = suppressWarnings(as.integer(label_included))
    ) |>
    dplyr::filter(!is.na(record_id), nzchar(record_id),
                  label %in% c(0L, 1L))
  n_out <- NROW(out)
  if (n_in != n_out) {
    message(sprintf("  %s: dropped %d/%d rows with missing IDs or non-binary labels",
                    dataset_name, n_in - n_out, n_in))
  }
  out
}

stratified_sample <- function(df, n_total, seed = 42) {
  set.seed(seed)
  prev <- mean(df$label == 1, na.rm = TRUE)
  n_pos <- max(1L, round(n_total * prev))
  n_neg <- n_total - n_pos
  pos <- df |> dplyr::filter(label == 1) |> dplyr::slice_sample(n = min(n_pos, sum(df$label == 1)))
  neg <- df |> dplyr::filter(label == 0) |> dplyr::slice_sample(n = min(n_neg, sum(df$label == 0)))
  dplyr::bind_rows(pos, neg) |> dplyr::slice_sample(prop = 1)  # shuffle
}

# ---- OpenAlex batched fetch for abstract + title -------------------------
# OpenAlex accepts up to 50 IDs per request via filter=openalex:W1|W2|...
# Reuses the direct-httr client from R/search.R (Bearer auth + credit guard).

fetch_openalex_meta <- function(ids, cache_key = digest::digest(ids)) {
  cache_path <- file.path(.SYN_DIR(), sprintf("cache_%s.rds", cache_key))
  if (file.exists(cache_path)) return(readRDS(cache_path))

  # Extract W-numbers from full URLs if needed.
  w_ids <- sub("^https?://openalex\\.org/", "", ids)
  chunks <- split(w_ids, ceiling(seq_along(w_ids) / 50))

  all_rows <- list()
  for (chunk in chunks) {
    url <- httr::modify_url("https://api.openalex.org/works",
                            query = list(
                              filter = paste0("openalex:", paste(chunk, collapse = "|")),
                              `per-page` = 50
                            ))
    body <- .oa_get(url)      # from search.R
    if (is.null(body)) { Sys.sleep(2); next }
    all_rows <- c(all_rows, body$results)
    Sys.sleep(1)
  }

  ai_to_text <- function(ai) {
    if (is.null(ai) || length(ai) == 0) return(NA_character_)
    pos <- integer(); words <- character()
    for (w in names(ai)) for (p in unlist(ai[[w]])) { pos <- c(pos, p); words <- c(words, w) }
    paste(words[order(pos)], collapse = " ")
  }

  out <- tibble::tibble(
    record_id = vapply(all_rows, function(x) x$id %||% NA_character_, ""),
    title     = vapply(all_rows, function(x) x$title %||% NA_character_, ""),
    abstract  = vapply(all_rows, function(x) ai_to_text(x$abstract_inverted_index), "")
  )
  saveRDS(out, cache_path)
  out
}

# ---- Metrics --------------------------------------------------------------

compute_metrics <- function(pred, actual) {
  # pred / actual are logical or 0/1 vectors of equal length
  pred   <- as.integer(as.logical(pred))
  actual <- as.integer(as.logical(actual))
  tp <- sum(pred == 1 & actual == 1)
  fp <- sum(pred == 1 & actual == 0)
  fn <- sum(pred == 0 & actual == 1)
  tn <- sum(pred == 0 & actual == 0)
  n  <- tp + fp + fn + tn

  sens <- if (tp + fn > 0) tp / (tp + fn) else NA_real_
  spec <- if (tn + fp > 0) tn / (tn + fp) else NA_real_
  prec <- if (tp + fp > 0) tp / (tp + fp) else NA_real_
  f1   <- if (!is.na(prec) && !is.na(sens) && (prec + sens) > 0) 2 * prec * sens / (prec + sens) else NA_real_

  # Cohen's kappa
  po <- (tp + tn) / n
  pyes <- ((tp + fp) / n) * ((tp + fn) / n)
  pno  <- ((tn + fn) / n) * ((tn + fp) / n)
  pe   <- pyes + pno
  kappa <- if (pe < 1) (po - pe) / (1 - pe) else NA_real_

  # MCC
  denom <- sqrt(as.numeric(tp+fp) * (tp+fn) * (tn+fp) * (tn+fn))
  mcc   <- if (denom > 0) (tp * tn - fp * fn) / denom else NA_real_

  # Gwet's AC1
  pi_e <- 2 * ((tp + fp + tp + fn) / (2 * n)) * (1 - (tp + fp + tp + fn) / (2 * n))
  ac1  <- if (pi_e < 1) (po - pi_e) / (1 - pi_e) else NA_real_

  tibble::tibble(n = n, tp = tp, fp = fp, fn = fn, tn = tn,
                 prevalence  = (tp + fn) / n,
                 sensitivity = sens,
                 specificity = spec,
                 precision   = prec,
                 f1 = f1, kappa = kappa, mcc = mcc, gwet_ac1 = ac1)
}
