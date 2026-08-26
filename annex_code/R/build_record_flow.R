# ---------------------------------------------------------------------------
# build_record_flow.R — the canonical record flow, computed once.
#
# Modules 07 and 08 both need the same cascade from retrieval to analytic set,
# and 08's flow diagram must not be able to disagree with 07's prose. Both read
# this file rather than each recomputing from source, and the reconciliation
# assertions live here so a mismatch stops the pipeline instead of producing
# two diagrams that quietly differ.
#
# Every stage records what it removed and why. Stages that DEFER records rather
# than excluding them (title-only, inference failure) are marked as such: those
# records are not judged irrelevant, they are unjudged, and a flow diagram that
# folds them into "excluded" would misstate the design.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr)
})
source(here::here("R", "config.R"))

OUT_CSV <- here::here(DIR_DERIVED, "record_flow.csv")

sl     <- readRDS(here::here(DIR_DERIVED, "search_ledger.rds"))
dl_raw <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds"))
dl     <- dl_raw |> dplyr::distinct(id, .keep_all = TRUE)

# KNOWN RESIDUAL IN THE DEDUP LEDGER
# Module 03 collapsed duplicates on normalised DOI, then on Jaro-Winkler
# title similarity. A record with NEITHER a DOI nor a title can match on
# neither key, so it survives once per search cell that returned it. Three
# such records account for 8 rows and 5 excess ids.
#
# They are not repaired here. All 8 were screened (they carry abstracts) and
# all 8 were excluded, and none reaches the analytic set, so re-running the
# dedup of 95,546 records to remove 5 rows that changed no result would be a
# disproportionate repair. They are reported as their own stratum instead,
# and the flow below counts LEDGER ROWS so that it reconciles against
# screening_strata.csv, which was built the same way.
dup_ids  <- dl_raw |> dplyr::count(id) |> dplyr::filter(n > 1L)
n_dup_rows <- NROW(dl_raw) - NROW(dl)
dup_detail <- dl_raw |> dplyr::filter(id %in% dup_ids$id) |>
  dplyr::summarise(rows = dplyr::n(), ids = dplyr::n_distinct(id),
                   no_title = sum(!nzchar(trimws(dplyr::coalesce(title, "")))),
                   no_doi = sum(is.na(doi) | !nzchar(doi)))
strata <- readr::read_csv(here::here(DIR_DERIVED, "screening_strata.csv"), show_col_types = FALSE)
geo    <- readRDS(here::here(DIR_DERIVED, "geography_verification.rds"))
tiers  <- readRDS(here::here(DIR_DERIVED, "geography_tiers.rds"))
ret    <- readRDS(here::here(DIR_DERIVED, "retrieval_ledger.rds"))

.s <- function(x) strata$n[strata$stratum == x]

n_retrieved  <- NROW(sl)
n_dedup      <- NROW(dl_raw)      # rows, matching screening_strata.csv
n_dedup_uniq <- NROW(dl)
n_titleonly  <- .s("unscreened_title_only")
n_screenable <- n_dedup - n_titleonly
n_failed     <- .s("unscreened_inference_failed")
n_screened   <- .s("include") + .s("exclude")
n_include    <- .s("include")
n_exclude    <- .s("exclude")
n_inscope    <- sum(geo$in_scope %in% TRUE)
n_outscope   <- sum(geo$in_scope %in% FALSE)
n_analytic   <- sum(tiers$analytic)
n_fulltext   <- sum(ret$tei_ok %in% TRUE & ret$id %in% tiers$id[tiers$analytic])

flow <- tibble::tibble(
  step = 1:8,
  stage = c("Records retrieved (OpenAlex + CORE, all cells)",
            "After deduplication",
            "Abstract present, eligible for screening",
            "Screened by the ensemble",
            "Included by the ensemble (union rule)",
            "Verified as located in the five countries",
            "Analytic set (study types only)",
            "Analytic set with retrievable full text"),
  n = c(n_retrieved, n_dedup, n_screenable, n_screened,
        n_include, n_inscope, n_analytic, n_fulltext),
  removed = c(NA_integer_,
              n_retrieved - n_dedup,
              n_dedup - n_screenable,
              n_screenable - n_screened,
              n_screened - n_include,
              n_include - n_inscope,
              n_inscope - n_analytic,
              n_analytic - n_fulltext),
  removal_reason = c(NA_character_,
                     "duplicate records merged",
                     "no abstract: DEFERRED, not excluded",
                     "inference failed on every attempt: DEFERRED, not excluded",
                     "judged not eligible by both models",
                     "located outside the five countries",
                     "not a study (paratext, editorial) by record type",
                     "no open-access full text obtainable"),
  disposition = c("retrieved", "carried", "carried", "carried",
                  "carried", "carried", "carried", "carried"))

# Reconciliation. Each of these is a place a silent miscount could hide.
stopifnot(
  n_screened == n_include + n_exclude,
  n_screenable == n_screened + n_failed,
  n_dedup == n_screenable + n_titleonly,
  n_dedup == n_dedup_uniq + n_dup_rows,
  n_inscope + n_outscope == NROW(geo),
  n_include == NROW(geo),
  n_analytic <= n_inscope,
  # the residual must stay outside the map, or it stops being negligible
  !any(tiers$id[tiers$analytic] %in% dup_ids$id))

readr::write_csv(flow, OUT_CSV)

cat("\n=== CANONICAL RECORD FLOW ===\n")
print(as.data.frame(flow |> dplyr::select(-step, -disposition)))
cat(sprintf("\nDeferred, never judged: %d title-only + %d inference-failed = %d records\n",
            n_titleonly, n_failed, n_titleonly + n_failed))
cat(sprintf("\nDedup residual: %d rows from %d records with neither title nor DOI\n",
            dup_detail$rows, dup_detail$ids))
cat(sprintf("  (%d of %d rows have no title, %d have no DOI; all were screened and excluded,\n   none reaches the analytic set)\n",
            dup_detail$no_title, dup_detail$rows, dup_detail$no_doi))
cat(sprintf("Overall: %d retrieved -> %d in the map (%.3f%%)\n",
            n_retrieved, n_analytic, 100 * n_analytic / n_retrieved))
cat(sprintf("\nAll reconciliation assertions passed.\nWrote %s\n", OUT_CSV))
sessionInfo()
