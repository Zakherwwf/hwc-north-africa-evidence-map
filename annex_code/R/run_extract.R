# ---------------------------------------------------------------------------
# run_extract.R — Module 06: run schema-constrained extraction over the
# analytic set and resolve every field through the four verification gates.
#
# INPUT   data/derived/geography_tiers.rds  (analytic == TRUE)
#         data/derived/retrieval_ledger.rds (which records have TEI)
#         data/derived/tei/*.tei.xml
# OUTPUT  data/derived/extraction_calls.rds   one row per model call
#         data/derived/extraction_fields.rds  one row per record x field
#         tables/extraction_reliability.csv   the per-field reliability table
#
# TWO EVIDENCE BASES, REPORTED SEPARATELY
# Only 122 of the 262 analytic records have retrievable full text. Extracting
# only from those would silently redefine the evidence map as a map of the
# open-access subset, and Module 05 already showed retrieval is uneven by
# country -- exactly the axis Module 07 measures. So every analytic record is
# extracted: from TEI methods/results where available, from title+abstract
# otherwise. `evidence_base` carries which, every summary is stratified by it,
# and fields that only full text can support are reported over the full-text
# stratum alone.
#
# SELF-CONSISTENCY COMPARISON
# Enum fields compare exactly after normalisation. Free-text fields also count
# as agreeing when one run's value contains the other's ("jackal" vs "golden
# jackal"), because a strict string test on free text measures phrasing, not
# extraction stability. Both numbers are in the reliability table; the NA rule
# uses strict for enums and lenient for free text.
#
# Usage:  Rscript R/run_extract.R [--limit N] [--no-xmodel] [--force]
# Resumable: every call is cached by content hash, so a re-run costs nothing
# for work already done.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr)
  library(jsonlite); library(purrr); library(tidyr)
})
readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "fulltext.R"))   # .safe_id, DIR_TEI
source(here::here("R", "extract.R"))

args      <- commandArgs(trailingOnly = TRUE)
.opt      <- function(f) f %in% args
.optval   <- function(f, d) { i <- match(f, args); if (is.na(i)) d else as.integer(args[i + 1]) }
LIMIT     <- .optval("--limit", NA_integer_)
DO_XMODEL <- !.opt("--no-xmodel")
FORCE     <- .opt("--force")

XMODEL_FRAC <- 0.20
XMODEL_SEED <- 2026L
PROBE_SEED  <- 7L

STAMP    <- format(Sys.Date(), "%Y%m%d")
LOG_PATH <- here::here(DIR_LOGS, sprintf("06_extract_%s.jsonl", STAMP))
.log <- function(x) cat(jsonlite::toJSON(c(x, list(when = format(Sys.time()))),
                        auto_unbox = TRUE, null = "null"), "\n",
                        file = LOG_PATH, append = TRUE)

ENUM_FIELDS <- unlist(lapply(FIELD_GROUPS, function(g)
  names(g)[!vapply(g, is.null, logical(1))]), use.names = FALSE)
FREE_FIELDS <- setdiff(EXTRACT_FIELDS, ENUM_FIELDS)

# Values that assert ABSENCE. No verbatim quote can support them: no paper
# contains a sentence saying "we tested no mitigation". Quote-grounding
# measures whether asserted PRESENCE is real, so absence values are exempt
# from it and verified instead by self-consistency and cross-model agreement.
#
# This is safe for the headline numbers because they are positive claims.
# "Studies evaluating a mitigation with a measured outcome" counts
# mitigation_outcome_measured == "yes", which IS grounded; the "no" values
# only sit in the complement. A model biased toward "no" would inflate that
# finding, so the bias is measured directly: the reliability table reports
# absence rate per field alongside cross-model agreement on the same rows.
UNQUOTABLE <- c(NOT_STATED, "no", "not measured")

# ---- 1. Assemble the work list --------------------------------------------

tiers <- readRDS(here::here(DIR_DERIVED, "geography_tiers.rds"))
ret   <- readRDS(here::here(DIR_DERIVED, "retrieval_ledger.rds"))
ledg  <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::distinct(id, .keep_all = TRUE)

work <- tiers |>
  dplyr::filter(analytic) |>
  dplyr::select(id, title, tier, study_country, type, publication_year,
                language, source_container) |>
  dplyr::left_join(ledg |> dplyr::select(id, abstract, doi, source), by = "id") |>
  dplyr::left_join(ret |> dplyr::select(id, country, tei_ok, has_methods), by = "id")

message(sprintf("Analytic set: %d records (%d with TEI)",
                NROW(work), sum(work$tei_ok %in% TRUE)))

# Resolve the text each record is extracted from.
texts <- purrr::map(seq_len(NROW(work)), function(i) {
  rec <- work[i, ]
  if (isTRUE(rec$tei_ok)) {
    tp <- here::here(DIR_TEI, paste0(.safe_id(rec$id), ".tei.xml"))
    if (file.exists(tp)) {
      s <- tei_sections(tp)
      if (!is.na(s$text) && nchar(s$text) >= 500)
        return(list(text = s$text, base = "full_text", source = s$source))
    }
  }
  ta <- trimws(paste(rec$title, dplyr::coalesce(rec$abstract, "")))
  if (nchar(ta) < 80) return(list(text = NA_character_, base = "none", source = "too_short"))
  list(text = ta, base = "title_abstract", source = "title_abstract")
})

work$evidence_base <- vapply(texts, `[[`, character(1), "base")
work$text_source   <- vapply(texts, `[[`, character(1), "source")
work$text          <- vapply(texts, `[[`, character(1), "text")
work$n_text_chars  <- nchar(work$text)

cat("\n=== evidence base for the analytic set ===\n")
print(work |> dplyr::count(evidence_base, text_source))

dropped <- work |> dplyr::filter(evidence_base == "none")
if (NROW(dropped)) {
  cat(sprintf("\nDROPPED %d records with no usable text:\n", NROW(dropped)))
  print(dropped |> dplyr::select(id, title) |> as.data.frame())
  .log(list(event = "dropped_no_text", n = NROW(dropped), ids = dropped$id))
}
work <- work |> dplyr::filter(evidence_base != "none")

if (!is.na(LIMIT)) work <- head(work, LIMIT)

# Cross-model subset: fixed seed so the 20% is stable across re-runs.
set.seed(XMODEL_SEED)
xm_ids <- sample(work$id, max(1L, round(XMODEL_FRAC * NROW(work))))
message(sprintf("Cross-model subset: %d of %d records", length(xm_ids), NROW(work)))

# ---- 2. Build the call plan (model-major: no model swap thrash) -----------

plan <- dplyr::bind_rows(
  tidyr::expand_grid(id = work$id, group = names(FIELD_GROUPS),
                     run_tag = c("main", "probe")) |>
    dplyr::mutate(model = EXTRACT_MODEL),
  if (DO_XMODEL)
    tidyr::expand_grid(id = xm_ids, group = names(FIELD_GROUPS), run_tag = "xmodel") |>
      dplyr::mutate(model = EXTRACT_XMODEL)
) |>
  dplyr::mutate(
    temperature = dplyr::if_else(run_tag == "probe", EXTRACT_TEMP_PROBE, EXTRACT_TEMP_MAIN),
    seed        = dplyr::if_else(run_tag == "probe", PROBE_SEED, OLLAMA_SEED)) |>
  dplyr::arrange(match(model, c(EXTRACT_MODEL, EXTRACT_XMODEL)), id, group)

message(sprintf("Planned calls: %d (%s)", NROW(plan),
                paste(sprintf("%s=%d", names(table(plan$model)), table(plan$model)),
                      collapse = ", ")))
.log(list(event = "run_start", n_records = NROW(work), n_calls = NROW(plan),
          model = EXTRACT_MODEL, xmodel = EXTRACT_XMODEL,
          num_ctx = EXTRACT_NUM_CTX, max_chars = EXTRACT_MAX_CHARS,
          temp_main = EXTRACT_TEMP_MAIN, temp_probe = EXTRACT_TEMP_PROBE))

# ---- 3. Execute ------------------------------------------------------------

txt_of <- setNames(work$text, work$id)
res <- vector("list", NROW(plan)); t0 <- Sys.time(); n_err <- 0L

for (i in seq_len(NROW(plan))) {
  p <- plan[i, ]
  o <- extract_group(record_id = p$id, text = txt_of[[p$id]], group_name = p$group,
                     model = p$model, temperature = p$temperature, seed = p$seed,
                     run_tag = p$run_tag, force = FORCE)
  ok <- isTRUE(o$ok)
  if (!ok) {
    n_err <- n_err + 1L
    .log(list(event = "call_failed", id = p$id, group = p$group, model = p$model,
              run_tag = p$run_tag, error = o$error %||% "unknown"))
  }
  res[[i]] <- tibble::tibble(id = p$id, group = p$group, model = p$model,
                             run_tag = p$run_tag, ok = ok,
                             error = if (ok) NA_character_ else (o$error %||% "unknown"),
                             fields = list(if (ok) o$fields else NULL))
  if (i %% 25 == 0 || i == NROW(plan)) {
    el <- as.numeric(Sys.time() - t0, units = "mins")
    message(sprintf("  [%d/%d] %.1f min, ETA %.1f min, %d errors",
                    i, NROW(plan), el, (NROW(plan) - i) * (el / i), n_err))
  }
}

calls <- dplyr::bind_rows(res)
saveRDS(calls, here::here(DIR_DERIVED, "extraction_calls.rds"))

# MANIFEST — the completeness contract for downstream modules.
#
# Module 07 originally guarded its extraction sections on file.exists(), which
# passed on the output of a 5-record smoke run and published a table reading
# "taxonomic_class (n = 4 studies)" as though it described the corpus. File
# existence is not evidence that a run covered the analytic set. This manifest
# records what the run actually did, and 07 refuses to use the output unless
# `complete` is TRUE.
manifest <- tibble::tibble(
  when          = format(Sys.time()),
  limit         = if (is.na(LIMIT)) NA_integer_ else as.integer(LIMIT),
  n_analytic    = NROW(tiers |> dplyr::filter(analytic)),
  n_records     = NROW(work),
  n_calls       = NROW(plan),
  n_calls_ok    = sum(calls$ok),
  n_calls_failed= sum(!calls$ok),
  xmodel        = DO_XMODEL,
  model         = EXTRACT_MODEL,
  xmodel_name   = EXTRACT_XMODEL,
  complete      = is.na(LIMIT) && sum(!calls$ok) == 0L)
saveRDS(manifest, here::here(DIR_DERIVED, "extraction_manifest.rds"))
cat("\n=== extraction manifest ===\n"); print(as.data.frame(manifest))
cat(sprintf("\nCalls: %d ok, %d failed (%.1f%%)\n", sum(calls$ok), sum(!calls$ok),
            100 * mean(!calls$ok)))
if (any(!calls$ok)) print(calls |> dplyr::filter(!ok) |> dplyr::count(model, error, sort = TRUE))

# ---- 4. Flatten to record x field, with grounding --------------------------

long <- purrr::pmap_dfr(
  list(calls$id, calls$group, calls$model, calls$run_tag, calls$ok, calls$fields),
  function(id, group, model, run_tag, ok, fl) {
    fnames <- names(FIELD_GROUPS[[group]])
    if (!ok || is.null(fl)) {
      return(tibble::tibble(id = id, group = group, model = model, run_tag = run_tag,
                            field = fnames, value = NA_character_,
                            quote = NA_character_, grounded = NA))
    }
    purrr::map_dfr(fnames, function(f) {
      x <- fl[[f]]
      v <- if (is.null(x$value)) NA_character_ else as.character(x$value)
      q <- if (is.null(x$evidence_quote)) NA_character_ else as.character(x$evidence_quote)
      tibble::tibble(id = id, group = group, model = model, run_tag = run_tag,
                     field = f, value = v, quote = q,
                     grounded = if (identical(v, NOT_STATED) || is.na(v)) NA
                                else ground_quote(q, txt_of[[id]]))
    })
  })

saveRDS(long, here::here(DIR_DERIVED, "extraction_long.rds"))

# ---- 5. Resolve each field through the gates ------------------------------

.agree <- function(a, b, field) {
  if (is.na(a) || is.na(b)) return(NA)
  na <- .norm(a); nb <- .norm(b)
  if (identical(na, nb)) return(TRUE)
  if (field %in% ENUM_FIELDS) return(FALSE)
  grepl(na, nb, fixed = TRUE) || grepl(nb, na, fixed = TRUE)
}
.agree_strict <- function(a, b) if (is.na(a) || is.na(b)) NA else identical(.norm(a), .norm(b))

wide <- long |>
  dplyr::filter(run_tag %in% c("main", "probe")) |>
  tidyr::pivot_wider(id_cols = c(id, group, field),
                     names_from = run_tag,
                     values_from = c(value, quote, grounded)) |>
  dplyr::rowwise() |>
  dplyr::mutate(
    consistent        = .agree(value_main, value_probe, field),
    consistent_strict = .agree_strict(value_main, value_probe)) |>
  dplyr::ungroup() |>
  dplyr::mutate(
    is_stated   = !is.na(value_main) & value_main != NOT_STATED,
    # A positive claim: something the text must actually say. Only these are
    # quote-grounded. A missing or too-short quote on a positive claim is a
    # grounding FAILURE, not an exemption -- hence %in% TRUE, not %in% FALSE.
    is_positive = is_stated & !(value_main %in% UNQUOTABLE),
    reason = dplyr::case_when(
      is.na(value_main)                        ~ "extraction_failed",
      !is_stated                               ~ NA_character_,
      is_positive & !(grounded_main %in% TRUE) ~ "unverified_quote",
      consistent %in% FALSE                    ~ "inconsistent_extraction",
      TRUE                                     ~ NA_character_),
    value_final = dplyr::if_else(is.na(reason) | !is_stated, value_main, NA_character_),
    value_final = dplyr::if_else(is.na(value_main), NA_character_, value_final)) |>
  dplyr::left_join(work |> dplyr::select(id, title, tier, study_country, country,
                                         evidence_base, text_source, publication_year,
                                         language, type, source_container, doi),
                   by = "id")

saveRDS(wide, here::here(DIR_DERIVED, "extraction_fields.rds"))

# ---- 6. Cross-model agreement ---------------------------------------------

xm <- long |>
  dplyr::filter(run_tag %in% c("main", "xmodel")) |>
  dplyr::filter(id %in% xm_ids) |>
  tidyr::pivot_wider(id_cols = c(id, field), names_from = run_tag, values_from = value) |>
  dplyr::rowwise() |>
  dplyr::mutate(xagree = .agree(main, xmodel, field)) |>
  dplyr::ungroup()

# ---- 7. Per-field reliability table ---------------------------------------

.rate <- function(x) if (!length(x)) NA_real_ else round(mean(x %in% TRUE), 3)

rel <- wide |>
  dplyr::group_by(field) |>
  dplyr::summarise(
    n              = dplyr::n(),
    n_stated       = sum(is_stated),
    pct_stated     = round(100 * mean(is_stated), 1),
    n_positive     = sum(is_positive),
    pct_absence    = round(100 * sum(is_stated & !is_positive) / max(1L, sum(is_stated)), 1),
    grounding      = .rate(grounded_main[is_positive]),
    self_consist   = .rate(consistent[is_stated]),
    self_strict    = .rate(consistent_strict[is_stated]),
    n_final        = sum(!is.na(value_final) & value_final != NOT_STATED),
    .groups = "drop") |>
  dplyr::left_join(
    xm |> dplyr::group_by(field) |>
      dplyr::summarise(n_xmodel = sum(!is.na(xagree)),
                       cross_model = .rate(xagree), .groups = "drop"),
    by = "field") |>
  dplyr::mutate(
    kind = dplyr::if_else(field %in% ENUM_FIELDS, "enum", "free_text"),
    # A measure with no rows to compute it on is unknown, not passing. Fields
    # the corpus never states cannot be certified reliable, so they fall below
    # the floor by definition and are reported as untestable.
    min_measure = pmin(dplyr::coalesce(grounding, -1),
                       dplyr::coalesce(self_consist, -1),
                       dplyr::coalesce(cross_model, -1)),
    reliable = min_measure >= FIELD_RELIABILITY_MIN,
    untestable = is.na(grounding) | is.na(self_consist) | is.na(cross_model)) |>
  dplyr::arrange(min_measure)

dir.create(here::here(DIR_TABLES), showWarnings = FALSE, recursive = TRUE)
readr::write_csv(rel, here::here(DIR_TABLES, "extraction_reliability.csv"))

cat("\n=== PER-FIELD RELIABILITY (grounding / self-consistency / cross-model) ===\n")
print(as.data.frame(rel |> dplyr::select(field, kind, n_stated, pct_stated, n_positive,
                                         pct_absence, grounding, self_consist,
                                         self_strict, cross_model, reliable, untestable)))
cat(sprintf("\nFields below the %.2f floor (excluded from headline analysis): %s\n",
            FIELD_RELIABILITY_MIN,
            paste(rel$field[!rel$reliable %in% TRUE], collapse = ", ")))

cat("\n=== reason for NA, over stated values ===\n")
print(wide |> dplyr::filter(is_stated) |> dplyr::count(reason, sort = TRUE))

cat("\n=== grounding by evidence base (positive claims only) ===\n")
print(wide |> dplyr::group_by(evidence_base) |>
      dplyr::summarise(n_stated = sum(is_stated), n_positive = sum(is_positive),
                       grounding = .rate(grounded_main[is_positive]),
                       self_consist = .rate(consistent[is_stated]), .groups = "drop"))

.log(list(event = "run_done", n_calls = NROW(calls), n_failed = sum(!calls$ok),
          n_fields = NROW(wide),
          unreliable = rel$field[!rel$reliable %in% TRUE],
          n_positive = sum(wide$is_positive),
          grounding_overall = .rate(wide$grounded_main[wide$is_positive])))

cat(sprintf("\nWrote %s\n      %s\n      %s\n",
            here::here(DIR_DERIVED, "extraction_calls.rds"),
            here::here(DIR_DERIVED, "extraction_fields.rds"),
            here::here(DIR_TABLES, "extraction_reliability.csv")))
sessionInfo()
