# ---------------------------------------------------------------------------
# run_citation_probe.R — how much did the search string itself miss?
#
# THE GAP THIS ADDRESSES
# The protocol's Module 02 calls for "backward and forward citation from the
# 20 highest-relevance records". That was never implemented: the search ledger
# contains only openalex_en, openalex_fr and core_en cells. So the corpus was
# built entirely from three narrow term blocks AND-ed together -- the same
# construction that returned 2 French and 0 Arabic records -- with no
# independent path in.
#
# WHAT THIS SCRIPT DOES, AND DOES NOT DO
# It does NOT add records to the corpus. Doing that now would mean re-running
# dedup, screening, the geography gate, full-text retrieval and extraction,
# and the analytic set is already downstream of all five.
#
# It measures instead. Every work cited by an analytic record is a work our
# own included studies considered relevant enough to cite. Applying our own
# search terms to those works tells us how many records the search string
# SHOULD have caught and did not. That is a direct, empirical estimate of
# search recall, and it is the only way to answer the mandated question of
# which apparent gaps are artefacts of the search string rather than real.
#
# THE STRING TEST IS AN APPROXIMATION
# It applies the three concept blocks to title+abstract, which is close to but
# not identical with the OpenAlex query the search actually issued. It is
# deliberately generous -- any geography term AND any conflict term -- so the
# resulting count is an UPPER bound on what the search should have found, and
# the shortfall it implies is an upper bound too. Both are reported as such.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr)
  library(jsonlite); library(httr); library(digest)
})
readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "search.R"))
source(here::here("R", "search_terms.R"))

CACHE     <- here::here("cache", "citation_probe")
OUT_PATH  <- here::here(DIR_DERIVED, "citation_probe.rds")
OUT_CSV   <- here::here(DIR_DERIVED, "citation_probe_candidates.csv")
LOG_PATH  <- here::here(DIR_LOGS, sprintf("02b_citation_probe_%s.jsonl", format(Sys.Date(), "%Y%m%d")))
N_FORWARD <- 20L
BATCH     <- 50L

.log <- function(x) cat(jsonlite::toJSON(c(x, list(when = format(Sys.time()))),
                        auto_unbox = TRUE, null = "null"), "\n",
                        file = LOG_PATH, append = TRUE)
dir.create(CACHE, showWarnings = FALSE, recursive = TRUE)

.bare <- function(x) sub("^.*/", "", x)

ai_to_text <- function(ai) {
  if (is.null(ai) || length(ai) == 0) return(NA_character_)
  pos <- integer(); words <- character()
  for (w in names(ai)) for (p in unlist(ai[[w]])) { pos <- c(pos, p); words <- c(words, w) }
  paste(words[order(pos)], collapse = " ")
}

.cached_get <- function(url, tag) {
  cp <- file.path(CACHE, sprintf("%s_%s.rds", tag, digest::digest(url, algo = "xxhash64")))
  if (file.exists(cp)) return(readRDS(cp))
  r <- .oa_get(url)
  if (is.null(r)) return(NULL)
  saveRDS(r, cp)
  r
}

tiers  <- readRDS(here::here(DIR_DERIVED, "geography_tiers.rds"))
ledger <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds"))
have   <- unique(.bare(ledger$id))

analytic <- tiers |> dplyr::filter(analytic) |> dplyr::filter(grepl("openalex\\.org/W", id))
seed_ids <- .bare(analytic$id)
message(sprintf("Seed set: %d analytic records with OpenAlex ids", length(seed_ids)))
.log(list(event = "run_start", n_seed = length(seed_ids), n_ledger = length(have)))

# ---- 1. Backward: everything the analytic records cite ---------------------

refs <- character(0); n_with_refs <- 0L
for (ch in split(seed_ids, ceiling(seq_along(seed_ids) / BATCH))) {
  url <- sprintf("%s/works?filter=openalex_id:%s&per-page=%d&select=id,referenced_works",
                 OPENALEX_BASE, paste(ch, collapse = "|"), BATCH)
  r <- .cached_get(url, "back")
  if (is.null(r)) { .log(list(event = "batch_failed", stage = "backward")); next }
  for (w in r$results) {
    n_with_refs <- n_with_refs + 1L
    refs <- c(refs, unlist(w$referenced_works))
  }
}
refs_u <- unique(.bare(refs))
message(sprintf("Backward: %d reference edges, %d unique works", length(refs), length(refs_u)))

# ---- 2. Forward: what cites the 20 highest-relevance seeds -----------------

seed_rel <- analytic |>
  dplyr::left_join(ledger |> dplyr::distinct(id, .keep_all = TRUE) |>
                     dplyr::select(id, relevance_score), by = "id") |>
  dplyr::arrange(dplyr::desc(dplyr::coalesce(relevance_score, -Inf))) |>
  head(N_FORWARD)

citing <- character(0)
for (sid in .bare(seed_rel$id)) {
  url <- sprintf("%s/works?filter=cites:%s&per-page=%d&select=id", OPENALEX_BASE, sid, 200L)
  r <- .cached_get(url, "fwd")
  if (is.null(r)) { .log(list(event = "batch_failed", stage = "forward", seed = sid)); next }
  citing <- c(citing, vapply(r$results, function(w) w$id %||% NA_character_, character(1)))
}
citing_u <- unique(.bare(citing[!is.na(citing)]))
message(sprintf("Forward: %d unique works citing the top %d seeds",
                length(citing_u), N_FORWARD))

# ---- 3. Which of these were already in the corpus? ------------------------

pool <- unique(c(refs_u, citing_u))
pool_new <- setdiff(pool, have)
message(sprintf("Citation pool: %d unique works, %d already in the ledger (%.1f%%), %d new",
                length(pool), sum(pool %in% have), 100 * mean(pool %in% have), length(pool_new)))

# ---- 4. Fetch metadata for the new ones and apply our own search terms ----

fetch_meta <- function(ids) {
  out <- list()
  chunks <- split(ids, ceiling(seq_along(ids) / BATCH))
  for (k in seq_along(chunks)) {
    url <- sprintf("%s/works?filter=openalex_id:%s&per-page=%d&select=id,doi,title,abstract_inverted_index,publication_year,language,type",
                   OPENALEX_BASE, paste(chunks[[k]], collapse = "|"), BATCH)
    r <- .cached_get(url, "meta")
    if (is.null(r)) { .log(list(event = "batch_failed", stage = "meta", k = k)); next }
    out <- c(out, r$results)
    if (k %% 20 == 0)
      message(sprintf("  metadata %d/%d batches, credits used %d",
                      k, length(chunks), .oa_env$credits_used))
    if (isTRUE(.oa_env$aborted)) { message("Credit guard tripped; stopping metadata fetch."); break }
  }
  out
}

meta_raw <- fetch_meta(pool_new)
message(sprintf("Fetched metadata for %d of %d new works", length(meta_raw), length(pool_new)))

meta <- tibble::tibble(
  id       = vapply(meta_raw, function(x) x$id %||% NA_character_, character(1)),
  doi      = vapply(meta_raw, function(x) x$doi %||% NA_character_, character(1)),
  title    = vapply(meta_raw, function(x) x$title %||% NA_character_, character(1)),
  abstract = vapply(meta_raw, function(x) ai_to_text(x$abstract_inverted_index) %||% NA_character_,
                    character(1)),
  year     = vapply(meta_raw, function(x) as.integer(x$publication_year %||% NA_integer_), integer(1)),
  language = vapply(meta_raw, function(x) x$language %||% NA_character_, character(1)),
  type     = vapply(meta_raw, function(x) x$type %||% NA_character_, character(1)))

GEO_PAT   <- paste(tolower(c(unlist(GEOGRAPHY_EN, use.names = FALSE), GEOGRAPHY_FR)), collapse = "|")
CONF_PAT  <- paste(tolower(c(CONFLICT_EN, CONFLICT_FR)), collapse = "|")
WILD_PAT  <- paste(tolower(c(WILDLIFE_EN, WILDLIFE_FR)), collapse = "|")

cand <- meta |>
  dplyr::mutate(
    ta        = tolower(paste(dplyr::coalesce(title, ""), dplyr::coalesce(abstract, ""))),
    has_geo   = grepl(GEO_PAT,  ta),
    has_conf  = grepl(CONF_PAT, ta),
    has_wild  = grepl(WILD_PAT, ta),
    in_year   = is.na(year) | year >= YEAR_FROM,
    # The generous test the header warns about: geography AND conflict. The
    # strict test additionally requires a wildlife term, which is what the
    # search actually AND-ed together.
    candidate_loose  = has_geo & has_conf & in_year,
    candidate_strict = has_geo & has_conf & has_wild & in_year)


readr::write_csv(cand |> dplyr::filter(candidate_strict) |> dplyr::select(-ta), OUT_CSV)

# ---- 5. Calibrate the test before believing any count it produces ---------
#
# The raw candidate count is uninterpretable on its own. The string test is
# NOT the query OpenAlex ran: the real search matched over more fields with
# stemming and synonym expansion, while this matches literal terms against
# title+abstract. So the test misses in-scope work, and by how much has to be
# measured before its output means anything.
#
# The calibration set is our own analytic records. Every one of them is a
# record the search DID find and the pipeline DID judge in scope, so the share
# the test flags is its sensitivity on exactly the kind of record we are
# hunting for. Detected counts are divided by that sensitivity to estimate how
# many were really there.
#
# Both sides are restricted to abstract-present records. Our analytic set is
# 100% abstract-present by construction; the citation pool is not, and a test
# reading title+abstract cannot be applied at the same strength to a record
# with no abstract.

calib <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::distinct(id, .keep_all = TRUE) |>
  dplyr::filter(id %in% analytic$id) |>
  dplyr::mutate(ta = tolower(paste(dplyr::coalesce(title, ""), dplyr::coalesce(abstract, ""))),
                has_geo = grepl(GEO_PAT, ta), has_conf = grepl(CONF_PAT, ta),
                has_wild = grepl(WILD_PAT, ta)) |>
  dplyr::filter(!is.na(abstract), nzchar(abstract))

sens_loose  <- mean(calib$has_geo & calib$has_conf)
sens_strict <- mean(calib$has_geo & calib$has_conf & calib$has_wild)

pool_ab <- cand |> dplyr::filter(!is.na(abstract), nzchar(abstract))
det_loose  <- sum(pool_ab$candidate_loose)
det_strict <- sum(pool_ab$candidate_strict)

# Clopper-Pearson on the detected count carries the small-number uncertainty
# through to the estimate; with single-digit detections it dominates.
.est <- function(det, n, sens) {
  ci <- stats::binom.test(det, n)$conf.int
  c(point = det / sens, lo = ci[1] * n / sens, hi = ci[2] * n / sens)
}
est_loose  <- .est(det_loose,  NROW(pool_ab), sens_loose)
est_strict <- .est(det_strict, NROW(pool_ab), sens_strict)

# The calibrated estimate is stored, not left to be recomputed downstream.
# Module 07 must not re-derive it from a different approximation of the same
# test -- that is how two numbers claiming to be the same quantity diverge.
estimate <- tibble::tibble(
  test        = c("loose", "strict"),
  sensitivity = c(sens_loose, sens_strict),
  detected    = c(det_loose, det_strict),
  pool_n      = NROW(pool_ab),
  estimate    = c(est_loose[["point"]], est_strict[["point"]]),
  ci_lo       = c(est_loose[["lo"]], est_strict[["lo"]]),
  ci_hi       = c(est_loose[["hi"]], est_strict[["hi"]]))

saveRDS(list(refs = refs_u, citing = citing_u, pool = pool, meta = cand,
             n_in_ledger = sum(pool %in% have), estimate = estimate),
        OUT_PATH)

# ---- 6. Report -------------------------------------------------------------

n_pool <- length(pool); n_have <- sum(pool %in% have)
n_loose <- sum(cand$candidate_loose); n_strict <- sum(cand$candidate_strict)

cat("\n=== CITATION PROBE ===\n")
cat(sprintf("Seed records (analytic, OpenAlex-indexed) : %d\n", length(seed_ids)))
cat(sprintf("Works they cite (unique)                  : %d\n", length(refs_u)))
cat(sprintf("Works citing the top %d by relevance      : %d\n", N_FORWARD, length(citing_u)))
cat(sprintf("Citation pool (unique)                    : %d\n", n_pool))
cat(sprintf("  already in our dedup ledger             : %d (%.1f%%)\n",
            n_have, 100 * n_have / n_pool))
cat(sprintf("  new, metadata retrieved                 : %d\n", NROW(cand)))

cat("\n--- calibration: what the string test does to records we KNOW are in scope ---\n")
cat(sprintf("Calibration set (analytic, abstract-present): %d\n", NROW(calib)))
cat(sprintf("  flagged by loose test  : %d (sensitivity %.3f)\n",
            sum(calib$has_geo & calib$has_conf), sens_loose))
cat(sprintf("  flagged by strict test : %d (sensitivity %.3f)\n",
            sum(calib$has_geo & calib$has_conf & calib$has_wild), sens_strict))
cat("\nThe test is far weaker than the search it stands in for, so raw counts\nbelow are floors and the calibrated estimates are the figures to read.\n")

cat("\n--- missed in-scope work in the citation pool ---\n")
cat(sprintf("Citation-pool works with abstracts        : %d\n", NROW(pool_ab)))
cat(sprintf("detected, loose test                      : %d  -> estimated %.0f  [95%% CI %.0f-%.0f]\n",
            det_loose, est_loose[["point"]], est_loose[["lo"]], est_loose[["hi"]]))
cat(sprintf("detected, strict test                     : %d  -> estimated %.0f  [95%% CI %.0f-%.0f]\n",
            det_strict, est_strict[["point"]], est_strict[["lo"]], est_strict[["hi"]]))
cat(sprintf("\nAgainst a %d-record analytic set, the strict estimate is %.1f%% [%.1f-%.1f%%].\n",
            NROW(analytic), 100 * est_strict[["point"]] / NROW(analytic),
            100 * est_strict[["lo"]] / NROW(analytic), 100 * est_strict[["hi"]] / NROW(analytic)))
cat(sprintf("Raw uncalibrated counts over all %d new works: loose %d, strict %d.\n",
            NROW(cand), n_loose, n_strict))

cat("\n--- language of the missed candidates ---\n")
print(cand |> dplyr::filter(candidate_strict) |> dplyr::count(language, sort = TRUE))
cat("\n--- type ---\n")
print(cand |> dplyr::filter(candidate_strict) |> dplyr::count(type, sort = TRUE))
cat("\n--- decade ---\n")
print(cand |> dplyr::filter(candidate_strict) |>
      dplyr::count(decade = 10 * (year %/% 10)) |> dplyr::arrange(decade))

cat("\n--- WHAT THIS PROBE CANNOT SEE ---\n")
cat("The pool is the citation neighbourhood of records we already found, so\n")
cat("the probe is conditioned on our own corpus and biased toward concluding\n")
cat("the search was complete. Literature disconnected from that neighbourhood\n")
cat("is invisible to it -- in particular francophone Maghreb work that our\n")
cat("English-only search missed AND that our included papers do not cite.\n")
cat("The estimate below bounds what citation chasing would have ADDED. It is\n")
cat("not a bound on what the search missed overall.\n")

cat("\n--- a sample of what the search missed ---\n")
print(cand |> dplyr::filter(candidate_strict) |> dplyr::slice_head(n = 15) |>
      dplyr::mutate(title = substr(title, 1, 78)) |>
      dplyr::select(year, language, title) |> as.data.frame())

.log(list(event = "run_done", n_pool = n_pool, n_have = n_have,
          n_new = NROW(cand), n_loose = n_loose, n_strict = n_strict,
          sens_loose = round(sens_loose, 3), sens_strict = round(sens_strict, 3),
          est_strict = round(est_strict[["point"]]),
          est_strict_lo = round(est_strict[["lo"]]), est_strict_hi = round(est_strict[["hi"]]),
          credits_used = .oa_env$credits_used))
cat(sprintf("\nOpenAlex credits used this run: %d (session cap %d)\n",
            .oa_env$credits_used, .OPENALEX_CREDIT_CAP))
cat(sprintf("Wrote %s\n      %s\n", OUT_PATH, OUT_CSV))
sessionInfo()
