# ---------------------------------------------------------------------------
# reduce_classifications.R — Module 04b reduce step.
#
# Walks the inference cache and collapses per-(model, run) votes into one
# ensemble decision per record, writing data/derived/classification_predictions.rds.
#
# Ensemble: gemma4:e4b + llama3:latest (qwen2.5:7b dropped 2026-08-22; the
# rationale and the ablation that justifies it are recorded in R/config.R).
# Polarity: affirmative. Decision rule: UNION — any model, any run, says
# include -> include. Scope: abstract-present records only.
#
# WHY THIS IS A SEPARATE SCRIPT
# The reduce block originally lived at the tail of run_classify_corpus.R and
# only executed after all inference passes completed. The 2026-08-22 crash hit
# mid-pass, so 210 hours of cached inference had produced no ledger at all.
# Splitting reduce out means the ledger can be rebuilt from cache at any time,
# and re-run cheaply whenever the cache gains records.
#
# WHAT THIS FIXES vs THE ORIGINAL REDUCE
# The original counted only ok=TRUE cache entries and set
#   ensemble_include <- votes_include > 0
# A record whose every vote failed therefore landed as n_votes = 0 and
# ensemble_include = FALSE — silently screened OUT, indistinguishable from a
# record the models genuinely rejected. 156 records were in that state. Here,
# coverage is recorded per record and incomplete records are reported as an
# explicit stratum rather than being absorbed into the excludes.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(jsonlite); library(digest); library(readr)
})
source(here::here("R", "config.R"))
source(here::here("R", "eligibility.R"))
source(here::here("R", "classifier.R"))

POLARITY  <- "affirmative"
MODELS    <- ENSEMBLE_MODELS
N_RUNS    <- N_RUNS_PER_ITEM
OUT_PATH  <- here::here(DIR_DERIVED, "classification_predictions.rds")
STRATA_CSV<- here::here(DIR_DERIVED, "screening_strata.csv")
LOG_PATH  <- here::here(DIR_LOGS, sprintf("04b_reduce_%s.jsonl", format(Sys.Date(), "%Y%m%d")))

build_criteria_text <- function(el) {
  border <- vapply(names(el$borderline), function(nm) {
    b <- el$borderline[[nm]]
    sprintf("- %s: verdict=%s. Rule: %s", gsub("_", " ", nm), b$verdict, b$rule)
  }, character(1))
  paste(
    paste("PCC:", el$pcc$population, "|",
          "Concept:", paste(el$pcc$concept, collapse = ", "), "|",
          "Context:", paste(el$pcc$context$countries, collapse = ", "),
          "(terrestrial + marine)"),
    "", "Include if ALL of these hold:", paste("-", el$include, collapse = "\n"),
    "", "Exclude if ANY of these apply:", paste("-", el$exclude, collapse = "\n"),
    "", "Borderline case rules (apply verbatim):", paste(border, collapse = "\n"),
    sep = "\n")
}
CRITERIA_TEXT <- build_criteria_text(ELIGIBILITY)
CRITERIA_HASH <- digest::digest(CRITERIA_TEXT, algo = "xxhash64")
stopifnot(identical(CRITERIA_HASH, "e021124a22ce6e9d"))
message("Criteria hash verified: ", CRITERIA_HASH)
message("Ensemble: ", paste(MODELS, collapse = " + "))

ledger <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::mutate(has_abstract = !is.na(abstract) & nzchar(abstract))
corpus <- ledger |> dplyr::filter(has_abstract)
n_title_only <- sum(!ledger$has_abstract)
message(sprintf("Corpus: %d abstract-present, %d title-only (deferred stratum)",
                NROW(corpus), n_title_only))

expected <- length(MODELS) * N_RUNS
res <- vector("list", NROW(corpus))
t0 <- Sys.time()
for (i in seq_len(NROW(corpus))) {
  rid <- corpus$id[i]
  vi <- 0L; vt <- 0L; repaired <- 0L
  for (model in MODELS) for (run_idx in seq_len(N_RUNS)) {
    p <- .cache_path_inf(model, POLARITY, rid, run_idx, CRITERIA_HASH)
    if (!file.exists(p)) next
    x <- tryCatch(jsonlite::read_json(p, simplifyVector = TRUE), error = function(e) NULL)
    if (is.null(x) || !isTRUE(x$ok)) next
    vt <- vt + 1L
    if (isTRUE(x$include)) vi <- vi + 1L
    if (identical(x$repair, "schema-constrained")) repaired <- repaired + 1L
  }
  res[[i]] <- tibble::tibble(id = rid, n_include_votes = vi, n_votes = vt,
                             n_repaired_votes = repaired,
                             coverage_complete = vt == expected,
                             ensemble_include  = vi > 0L)
  if (i %% 10000 == 0)
    message(sprintf("  ...%d/%d (%.1f min)", i, NROW(corpus),
                    as.numeric(Sys.time() - t0, units = "mins")))
}
final <- dplyr::bind_rows(res)

# Records with no usable vote at all cannot be called either way. They are NOT
# excludes; they are unscreened, and must be reported as such.
final <- final |> dplyr::mutate(
  screened = n_votes > 0L,
  status = dplyr::case_when(
    n_votes == 0L    ~ "unscreened_inference_failed",
    ensemble_include ~ "include",
    TRUE             ~ "exclude"))

saveRDS(final, OUT_PATH)

strata <- tibble::tribble(
  ~stratum, ~n,
  "include",                       sum(final$status == "include"),
  "exclude",                       sum(final$status == "exclude"),
  "unscreened_inference_failed",   sum(final$status == "unscreened_inference_failed"),
  "unscreened_title_only",         n_title_only)
readr::write_csv(strata, STRATA_CSV)

cat(jsonlite::toJSON(list(event = "reduce_done", ensemble = MODELS,
      polarity = POLARITY, criteria_hash = CRITERIA_HASH,
      n_abstract_present = NROW(corpus), n_title_only = n_title_only,
      n_include = sum(final$status == "include"),
      n_exclude = sum(final$status == "exclude"),
      n_unscreened = sum(final$status == "unscreened_inference_failed"),
      n_incomplete_coverage = sum(!final$coverage_complete),
      n_records_with_repaired_votes = sum(final$n_repaired_votes > 0),
      when = format(Sys.time())), auto_unbox = TRUE), "\n",
    file = LOG_PATH, append = TRUE)

cat("\n=== REDUCE DONE ===\n")
print(strata)
cat(sprintf("\nIncludes: %d / %d screened (%.2f%%)\n",
            sum(final$status == "include"), sum(final$screened),
            100 * sum(final$status == "include") / sum(final$screened)))
cat(sprintf("Records with incomplete vote coverage (<%d votes): %d\n",
            expected, sum(!final$coverage_complete)))
cat(sprintf("Records carrying >=1 schema-constrained repaired vote: %d\n",
            sum(final$n_repaired_votes > 0)))
cat(sprintf("\nWrote %s\n     %s\n", OUT_PATH, STRATA_CSV))
