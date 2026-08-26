# ---------------------------------------------------------------------------
# run_classify_corpus.R — Module 04b: classify the real HWC corpus.
#
# Configuration (per user decision, calibrated by Module 04a):
#   - Ensemble: gemma4:e4b + llama3:latest + qwen2.5:7b
#   - Polarity: affirmative (only phrasing where all 3 models cooperate)
#   - Runs per record: 2 (self-consistency; at temp 0 largely redundant
#     but kept for full protocol compliance)
#   - Decision rule: UNION (any model + any run says include -> include)
#   - Scope: abstract-present records only (~61,065 records)
#     Title-only records (~4,747) are logged as a separate "unscreened"
#     stratum reported in Module 09.
#
# Estimated runtime: ~8.5 days on a 16 GB Apple Silicon Mac serving
# models sequentially. The job is fully resumable: every prediction is
# cached to disk keyed on (model, polarity, record_id, run_idx, criteria).
# If interrupted, re-launch and it picks up where it left off.
#
# Robustness:
#   - Intermediate ledger saved every CHECKPOINT_EVERY records.
#   - Per-record wall-clock logged; ETA computed and printed each checkpoint.
#   - Any single-record failure logged and skipped (does not abort the run).
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(jsonlite); library(digest)
})
readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "eligibility.R"))
source(here::here("R", "classifier.R"))

# ---- Configuration --------------------------------------------------------
POLARITY         <- "affirmative"
MODELS           <- ENSEMBLE_MODELS          # gemma+llama+qwen
N_RUNS           <- N_RUNS_PER_ITEM          # 2
CHECKPOINT_EVERY <- 500L
OUT_PATH         <- here::here(DIR_DERIVED, "classification_predictions.rds")
LOG_PATH         <- here::here(DIR_LOGS, sprintf(
                     "04b_classify_%s.jsonl", format(Sys.Date(), "%Y%m%d")))

# ---- Build the classifier's criteria text from the frozen eligibility ----
# The exact string below is what goes into the affirmative prompt. Any
# change to R/eligibility.R changes the criteria hash and invalidates
# the cache — that is the intended invariant.

build_criteria_text <- function(el) {
  border <- vapply(names(el$borderline), function(nm) {
    b <- el$borderline[[nm]]
    sprintf("- %s: verdict=%s. Rule: %s",
            gsub("_", " ", nm), b$verdict, b$rule)
  }, character(1))

  paste(
    paste("PCC:", el$pcc$population, "|",
          "Concept:", paste(el$pcc$concept, collapse = ", "), "|",
          "Context:", paste(el$pcc$context$countries, collapse = ", "),
          "(terrestrial + marine)"),
    "",
    "Include if ALL of these hold:",
    paste("-", el$include, collapse = "\n"),
    "",
    "Exclude if ANY of these apply:",
    paste("-", el$exclude, collapse = "\n"),
    "",
    "Borderline case rules (apply verbatim):",
    paste(border, collapse = "\n"),
    sep = "\n"
  )
}

CRITERIA_TEXT <- build_criteria_text(ELIGIBILITY)
CRITERIA_HASH <- digest::digest(CRITERIA_TEXT, algo = "xxhash64")

# ---- Load corpus, restrict to abstract-present ---------------------------

ledger <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds"))
ledger <- ledger |>
  dplyr::mutate(has_abstract = !is.na(abstract) & nzchar(abstract))
corpus <- ledger |> dplyr::filter(has_abstract)
message(sprintf("Corpus (abstract-present): %d records", NROW(corpus)))
message(sprintf("Deferred (title-only, logged separately): %d records",
                sum(!ledger$has_abstract)))
message(sprintf("Criteria hash: %s", CRITERIA_HASH))

# ---- Reload prior results if any (resume) --------------------------------

if (file.exists(OUT_PATH)) {
  prior <- readRDS(OUT_PATH)
  done_ids <- prior$id
  message(sprintf("Resuming: %d records already have final predictions",
                  length(done_ids)))
} else {
  prior <- tibble::tibble(
    id = character(), n_include_votes = integer(),
    n_votes = integer(), ensemble_include = logical()
  )
  done_ids <- character(0)
}

todo <- corpus |> dplyr::filter(!id %in% done_ids)
message(sprintf("Remaining to classify: %d", NROW(todo)))

# ---- Logging helper -------------------------------------------------------
.log <- function(record) {
  dir.create(dirname(LOG_PATH), showWarnings = FALSE, recursive = TRUE)
  cat(jsonlite::toJSON(c(record, list(when = format(Sys.time()))),
                       auto_unbox = TRUE, null = "null"), "\n",
      file = LOG_PATH, append = TRUE)
}

# ---- Main loop — MODEL-MAJOR ordering ------------------------------------
# On 16 GB Apple Silicon we cannot keep all three ensemble models loaded
# simultaneously. Iterating per-record forces Ollama to swap models every
# few seconds, which multiplied inference time ~3x in the smoke test.
# Iterating model-major (all records for model A, then B, then C) keeps
# one model warm at a time and lets Ollama's keep-alive do the right thing.
#
# Cache is content-addressed by (model, polarity, record_id, run_idx,
# criteria_hash) so pass order does not affect final per-record ensemble
# decision, only wall-clock time.

.log(list(event = "run_start", n_todo = NROW(todo),
          models = MODELS, polarity = POLARITY, n_runs = N_RUNS,
          criteria_hash = CRITERIA_HASH))
t0 <- Sys.time()

# --- Pass 1..N: run each model over the entire todo list, single fn call --
for (mi in seq_along(MODELS)) {
  model <- MODELS[mi]
  message(sprintf("\n=== Pass %d/%d: model = %s ===", mi, length(MODELS), model))
  t_model <- Sys.time()
  for (i in seq_len(NROW(todo))) {
    rec <- todo[i, ]
    # classify_record with models = <single model> populates the cache
    # for THAT model without touching the others. Cheap; the cache-hit
    # path is a file existence check.
    tryCatch(
      classify_record(
        record_id     = rec$id,
        title         = rec$title,
        abstract      = rec$abstract,
        criteria_text = CRITERIA_TEXT,
        models        = model,
        polarity      = POLARITY,
        n_runs        = N_RUNS
      ),
      error = function(e) {
        .log(list(event = "record_error", model = model,
                  record_id = rec$id, error = conditionMessage(e)))
      }
    )
    if (i %% CHECKPOINT_EVERY == 0 || i == NROW(todo)) {
      elapsed_model <- as.numeric(Sys.time() - t_model, units = "secs")
      per_rec       <- elapsed_model / i
      remain_model  <- (NROW(todo) - i) * per_rec
      elapsed_total <- as.numeric(Sys.time() - t0, units = "secs")
      .log(list(event = "checkpoint", pass = mi, model = model,
                records_done_in_pass = i, records_remaining_in_pass = NROW(todo) - i,
                elapsed_hours_this_pass = round(elapsed_model / 3600, 2),
                eta_hours_this_pass     = round(remain_model / 3600, 2),
                elapsed_hours_total     = round(elapsed_total / 3600, 2)))
      message(sprintf("  [%s %d/%d] pass elapsed %.1fh  ETA this pass %.1fh  total %.1fh",
                      model, i, NROW(todo),
                      elapsed_model/3600, remain_model/3600, elapsed_total/3600))
    }
  }
}

# --- Reduce: for each record, walk the cache to compute ensemble vote ----
message("\nReducing per-record ensemble decisions...")
new_results <- vector("list", NROW(todo))
for (i in seq_len(NROW(todo))) {
  rec <- todo[i, ]
  votes_include <- 0L; votes_total <- 0L
  for (model in MODELS) for (run_idx in seq_len(N_RUNS)) {
    cache_path <- .cache_path_inf(model, POLARITY, rec$id, run_idx, CRITERIA_HASH)
    if (!file.exists(cache_path)) next
    x <- tryCatch(jsonlite::read_json(cache_path, simplifyVector = TRUE),
                  error = function(e) NULL)
    if (is.null(x) || !isTRUE(x$ok)) next
    votes_total   <- votes_total + 1L
    if (isTRUE(x$include)) votes_include <- votes_include + 1L
  }
  new_results[[i]] <- tibble::tibble(
    id               = rec$id,
    n_include_votes  = votes_include,
    n_votes          = votes_total,
    ensemble_include = votes_include > 0L
  )
}

final <- dplyr::bind_rows(prior, dplyr::bind_rows(new_results))
saveRDS(final, OUT_PATH)

cat(sprintf("\n=== DONE. Total classified: %d records ===\n", NROW(final)))
cat(sprintf("Ensemble includes: %d (%.1f%%)\n",
            sum(final$ensemble_include),
            100 * mean(final$ensemble_include)))
