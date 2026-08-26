# ---------------------------------------------------------------------------
# model_agreement.R — Module 04b, the three quantities the protocol requires
# as results in their own right:
#
#   * inter-model agreement   (raw agreement and Cohen's kappa between models)
#   * self-consistency        (agreement between runs of the same model)
#   * the contested set       (records the models disagree about)
#
# WHY THIS IS A SEPARATE PASS
# reduce_classifications.R collapses the inference cache to a vote COUNT per
# record (n_include_votes out of n_votes). That is all the union rule needs,
# but it discards which model cast which vote, and every quantity above needs
# exactly that. So this walks the cache a second time and keeps model identity.
#
# The cache holds one JSON per (model, polarity, record, run). Model, record id
# and run index are recorded inside each file, so the votes are recoverable
# without re-running any inference -- ~317k file reads, about ninety seconds.
#
# READ THE SELF-CONSISTENCY NUMBER CAREFULLY
# Both runs use temperature 0 with the same seed, and greedy decoding is
# deterministic, so identical inputs must produce identical outputs. A
# self-consistency of 1.00 here is therefore a decoding property, not evidence
# that the classifier is stable under perturbation. It is reported because the
# protocol asks for it, and it is reported WITH this caveat every time. Module
# 06 measures real robustness instead, by perturbing temperature between runs.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr); library(jsonlite); library(tidyr)
})
source(here::here("R", "config.R"))

CACHE_DIR <- here::here(DIR_CACHE_INFERENCE)
OUT_VOTES <- here::here(DIR_DERIVED, "classification_votes.rds")
OUT_AGREE <- here::here(DIR_TABLES, "04b_model_agreement.csv")
OUT_CONT  <- here::here(DIR_DERIVED, "contested_set.rds")
LOG_PATH  <- here::here(DIR_LOGS, sprintf("04b_agreement_%s.jsonl", format(Sys.Date(), "%Y%m%d")))

.log <- function(x) cat(jsonlite::toJSON(c(x, list(when = format(Sys.time()))),
                        auto_unbox = TRUE, null = "null"), "\n",
                        file = LOG_PATH, append = TRUE)

# ---- 1. Walk the cache -----------------------------------------------------

.str_field <- function(x, key) {
  m <- regexpr(sprintf('"%s":"[^"]*"', key), x)
  out <- rep(NA_character_, length(x)); hit <- m > 0
  out[hit] <- sub(sprintf('^"%s":"', key), "", sub('"$', "", regmatches(x, m)))
  out
}
.int_field <- function(x, key) {
  m <- regexpr(sprintf('"%s":[0-9]+', key), x)
  out <- rep(NA_integer_, length(x)); hit <- m > 0
  out[hit] <- as.integer(sub(sprintf('"%s":', key), "", regmatches(x, m)))
  out
}
# "include" and "ok" are read as anchored literals rather than parsed, because
# the `raw` field in each file contains the model's own JSON text and would
# otherwise match. Both keys appear before `raw` and only once outside it.
.bool_field <- function(x, key) {
  m <- regexpr(sprintf('"%s":(true|false)', key), x)
  out <- rep(NA, length(x)); hit <- m > 0
  out[hit] <- grepl("true$", regmatches(x, m))
  out
}

files <- list.files(CACHE_DIR, pattern = "\\.json$", full.names = TRUE)
message(sprintf("Reading %d cached inference calls from %s", length(files), CACHE_DIR))
t0 <- Sys.time()
raw <- vapply(files, function(p) paste(readLines(p, warn = FALSE), collapse = ""),
              character(1), USE.NAMES = FALSE)
message(sprintf("  read in %.1f s", as.numeric(Sys.time() - t0, units = "secs")))

# `confidence` is carried through because Module 07's robustness pass has to
# recompute every headline count over high-confidence classifications only,
# and that field exists nowhere else once the cache is collapsed to votes.
votes <- tibble::tibble(
  id         = .str_field(raw, "record_id"),
  model      = .str_field(raw, "model"),
  polarity   = .str_field(raw, "polarity"),
  run_idx    = .int_field(raw, "run_idx"),
  ok         = .bool_field(raw, "ok"),
  include    = .bool_field(raw, "include"),
  confidence = .str_field(raw, "confidence"))

stopifnot(!any(is.na(votes$id)), !any(is.na(votes$model)))

cat("\n=== cached votes ===\n")
print(votes |> dplyr::count(model, polarity, run_idx, ok))

# The deployed configuration only, on the corpus actually screened.
#
# Two kinds of stale entry live in this cache and both have to go. qwen2.5:7b
# votes are from the pre-2026-08-22 ensemble, excluded for the same reason
# config.R excludes qwen from ENSEMBLE_MODELS. Less obviously, Module 04a's
# benchmark validation ran the same models at the same polarity over SYNERGY
# records, and the criteria hash that separates those runs lives in the cache
# FILENAME, not inside the file -- so a content-only walk cannot see it. Those
# records are excluded by restricting to ids Module 04b actually attempted,
# which is also what makes the arithmetic below reconcile against the 550
# ensemble includes.
preds <- readRDS(here::here(DIR_DERIVED, "classification_predictions.rds"))
n_incl <- sum(preds$status == "include")

v <- votes |>
  dplyr::filter(polarity == "affirmative", model %in% ENSEMBLE_MODELS, ok %in% TRUE)
n_before <- dplyr::n_distinct(v$id)
v <- v |> dplyr::filter(id %in% preds$id)
message(sprintf("Records in cache: %d; screened by Module 04b: %d; dropped as stale (04a benchmark or pre-dedup): %d",
                n_before, dplyr::n_distinct(v$id), n_before - dplyr::n_distinct(v$id)))
message(sprintf("Deployed-config votes: %d over %d records",
                NROW(v), dplyr::n_distinct(v$id)))
saveRDS(votes, OUT_VOTES)

# The repair pass re-cached some (record, model, run) triples under a fresh
# key, so a few appear twice. Collapse them under the same union the ensemble
# uses everywhere else, and report how many were affected.
dup <- v |> dplyr::count(id, model, run_idx) |> dplyr::filter(n > 1L)
if (NROW(dup))
  message(sprintf("Duplicate (record, model, run) triples collapsed by union: %d",
                  NROW(dup)))
v <- v |>
  dplyr::group_by(id, model, run_idx) |>
  dplyr::summarise(include = any(include %in% TRUE),
                   confidence = dplyr::first(confidence[!is.na(confidence)]),
                   .groups = "drop")

cat("\n=== confidence reported with each include vote ===\n")
print(v |> dplyr::filter(include) |> dplyr::count(model, confidence))

# ---- 2. Self-consistency, per model ---------------------------------------

selfc <- v |>
  dplyr::filter(run_idx %in% c(1L, 2L)) |>
  tidyr::pivot_wider(id_cols = c(id, model), names_from = run_idx,
                     names_prefix = "run", values_from = include) |>
  dplyr::filter(!is.na(run1), !is.na(run2), is.logical(run1), is.logical(run2)) |>
  dplyr::group_by(model) |>
  dplyr::summarise(n_records = dplyr::n(),
                   self_consistency = mean(run1 == run2),
                   n_flipped = sum(run1 != run2), .groups = "drop")
cat("\n=== self-consistency (runs 1 vs 2 of the same model, temperature 0) ===\n")
print(as.data.frame(selfc))

# ---- 3. Per-model decision, then inter-model agreement --------------------
# A model includes a record if ANY of its runs includes it -- the same union
# applied within a model that the ensemble applies across models.

per_model <- v |>
  dplyr::group_by(id, model) |>
  dplyr::summarise(includes = any(include %in% TRUE), .groups = "drop") |>
  tidyr::pivot_wider(id_cols = id, names_from = model, values_from = includes)

# Per record: the highest confidence attached to any include vote. Module 07
# filters on this for the high-confidence robustness variant.
CONF_ORDER <- c("low", "medium", "high")
include_conf <- v |>
  dplyr::filter(include, !is.na(confidence)) |>
  dplyr::mutate(rank = match(tolower(confidence), CONF_ORDER)) |>
  dplyr::group_by(id) |>
  dplyr::summarise(max_confidence = CONF_ORDER[max(rank, na.rm = TRUE)],
                   min_confidence = CONF_ORDER[min(rank, na.rm = TRUE)],
                   n_include_votes = dplyr::n(), .groups = "drop")
saveRDS(include_conf, here::here(DIR_DERIVED, "include_confidence.rds"))
cat("\n=== confidence of the include decision, per record ===\n")
print(include_conf |> dplyr::count(max_confidence, min_confidence))

m1 <- ENSEMBLE_MODELS[1]; m2 <- ENSEMBLE_MODELS[2]
both <- per_model |> dplyr::filter(!is.na(.data[[m1]]), !is.na(.data[[m2]]))
a <- both[[m1]]; b <- both[[m2]]

n   <- length(a)
n11 <- sum(a & b); n10 <- sum(a & !b); n01 <- sum(!a & b); n00 <- sum(!a & !b)
po  <- (n11 + n00) / n
pe  <- ((n11 + n10) / n) * ((n11 + n01) / n) + ((n01 + n00) / n) * ((n10 + n00) / n)
kappa <- (po - pe) / (1 - pe)
# Prevalence-adjusted bias-adjusted kappa. At 0.9% prevalence Cohen's kappa is
# dominated by the enormous agreed-exclude cell; PABAK strips that dependence
# and is reported alongside for the same reason 04a reports MCC and AC1.
pabak <- 2 * po - 1

cat("\n=== inter-model agreement (union within model, over records both scored) ===\n")
cat(sprintf("models: %s vs %s\n", m1, m2))
print(matrix(c(n11, n10, n01, n00), 2, 2, byrow = TRUE,
             dimnames = list(paste(m1, c("include", "exclude")),
                             paste(m2, c("include", "exclude")))))
cat(sprintf("\nrecords compared     : %d\nraw agreement        : %.4f\nCohen's kappa        : %.4f\nPABAK                : %.4f\n",
            n, po, kappa, pabak))

# ---- 4. The contested set --------------------------------------------------

# Record arithmetic must reconcile: the union rule says an include is any
# record either model included, so both-include + either-only must equal the
# 550 in the ledger. If it does not, the vote set and the ledger disagree and
# the discrepancy is reported rather than absorbed.
n_union <- n11 + n10 + n01

# `both` holds only records where BOTH models returned a usable decision. A
# record one model failed on entirely still counts as an ensemble include if
# the other model included it, so it is a ledger include with no agreement to
# measure. Those records are the whole of the difference, and naming them is
# the reconciliation -- an unexplained residual would not be.
single_cov <- per_model |>
  dplyr::filter(is.na(.data[[m1]]) | is.na(.data[[m2]])) |>
  dplyr::filter(dplyr::coalesce(.data[[m1]], FALSE) | dplyr::coalesce(.data[[m2]], FALSE))
cat(sprintf("\nreconciliation: %d both-model includes + %d single-model-coverage includes = %d; ledger = %d %s\n",
            n_union, NROW(single_cov), n_union + NROW(single_cov), n_incl,
            if (n_union + NROW(single_cov) == n_incl) "(reconciles)" else "(MISMATCH)"))
if (n_union + NROW(single_cov) != n_incl)
  warning(sprintf("Record arithmetic does not reconcile: %d vs %d",
                  n_union + NROW(single_cov), n_incl))

contested <- both |>
  dplyr::filter(.data[[m1]] != .data[[m2]]) |>
  dplyr::mutate(included_by = dplyr::if_else(.data[[m1]], m1, m2))

ledg <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::distinct(id, .keep_all = TRUE) |>
  dplyr::select(id, title, publication_year, cell_id, source, type)
contested <- contested |> dplyr::left_join(ledg, by = "id") |>
  dplyr::mutate(cell_country = sub("^[a-z]+_[a-z]+_", "", cell_id))
saveRDS(contested, OUT_CONT)

cat("\n=== contested set ===\n")
cat(sprintf("size: %d records (%.2f%% of %d scored)\n", NROW(contested),
            100 * NROW(contested) / n, n))
cat(sprintf("as a share of the %d ensemble includes: %.1f%%\n",
            n_incl, 100 * NROW(contested) / n_incl))
cat("\nwhich model pulled each contested record in:\n")
print(contested |> dplyr::count(included_by, sort = TRUE))
cat("\ncontested records by search cell:\n")
print(contested |> dplyr::count(cell_country, sort = TRUE))

# ---- 5. Write the agreement table -----------------------------------------

agree_tbl <- tibble::tibble(
  quantity = c("records scored by both models",
               "raw inter-model agreement", "Cohen's kappa", "PABAK",
               "both include", "only gemma includes", "only llama includes",
               "both exclude",
               "contested set size", "contested as % of ensemble includes",
               paste0("self-consistency, ", selfc$model)),
  value = c(n, round(po, 4), round(kappa, 4), round(pabak, 4),
            n11, n10, n01, n00,
            NROW(contested), round(100 * NROW(contested) / n_incl, 1),
            round(selfc$self_consistency, 4)))
dir.create(here::here(DIR_TABLES), showWarnings = FALSE, recursive = TRUE)
readr::write_csv(agree_tbl, OUT_AGREE)

.log(list(event = "agreement", n_compared = n, raw_agreement = round(po, 4),
          kappa = round(kappa, 4), pabak = round(pabak, 4),
          contested = NROW(contested),
          self_consistency = as.list(setNames(round(selfc$self_consistency, 4),
                                              selfc$model))))
cat(sprintf("\nWrote %s\n      %s\n      %s\n", OUT_VOTES, OUT_CONT, OUT_AGREE))
sessionInfo()
