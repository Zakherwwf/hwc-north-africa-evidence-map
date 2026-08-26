# ---------------------------------------------------------------------------
# repair_failed_classifications.R — Module 04b repair pass.
#
# WHY THIS EXISTS
# During the 04b corpus run, 682 inference calls returned unusable results and
# were cached as ok=FALSE. Because classify_record() treats ANY cached file as
# a hit, those failures were sticky: re-launching the run would never retry
# them. They are invisible in the main log (no record_error events fired,
# since .classify_one() returns a value rather than signalling a condition).
#
# Two distinct failure modes:
#   - 60  "HTTP no-response"  transient Ollama timeouts.
#   - 622 "schema-invalid"    the model emitted VALID JSON with entirely wrong
#                             keys -- summarising the paper instead of screening
#                             it. Triggered by pathological records whose
#                             "abstract" field holds full book-review or
#                             dictionary text (the worst is 18,093 chars).
#
# WHY A PLAIN RETRY CANNOT WORK
# .classify_one() calls Ollama with temperature = 0, i.e. greedy decoding.
# Generation is therefore deterministic and the seed has no effect. Re-issuing
# the identical request returns byte-identical output, so a naive retry -- with
# or without a fresh seed -- reproduces the same failure forever.
#
# THE REPAIR
# Re-issue the SAME prompt, at the SAME temperature, but pass an explicit JSON
# Schema in Ollama's `format` field (structured outputs, Ollama >= 0.5) instead
# of the bare format="json". This constrains decoding to the required keys.
# The prompt text, model, polarity and criteria are unchanged, so the repaired
# call answers exactly the question the original asked.
#
# DEVIATION NOTE (report this in Module 09)
# This is a documented, targeted deviation affecting 156 of 61,065 records
# (0.26%). Repaired predictions are flagged `repair = "schema-constrained"` in
# the cache payload so they can be audited or excluded. Original failed
# payloads are preserved to logs/04b_failed_raw_<date>.jsonl before being
# overwritten -- nothing is destroyed silently.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(jsonlite); library(httr); library(digest)
})
readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "eligibility.R"))
source(here::here("R", "classifier.R"))

POLARITY <- "affirmative"
MODELS   <- c("gemma4:e4b", "llama3:latest")   # qwen dropped -- see 04b decision note
N_RUNS   <- N_RUNS_PER_ITEM
MAX_TRIES <- 3L

STAMP        <- format(Sys.Date(), "%Y%m%d")
LOG_PATH     <- here::here(DIR_LOGS, sprintf("04b_repair_%s.jsonl", STAMP))
QUARANTINE   <- here::here(DIR_LOGS, sprintf("04b_failed_raw_%s.jsonl", STAMP))

# ---- Criteria text: byte-identical to run_classify_corpus.R ---------------
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

# Hard invariant: if this hash drifts, every cache key below points at the
# wrong file and the repair would silently write into a parallel universe.
stopifnot(identical(CRITERIA_HASH, "e021124a22ce6e9d"))
message("Criteria hash verified: ", CRITERIA_HASH)

# ---- Schema-constrained variant of .classify_one --------------------------
RESPONSE_SCHEMA <- list(
  type = "object",
  properties = list(
    include           = list(type = "boolean"),
    confidence        = list(type = "string", enum = c("low", "medium", "high")),
    primary_reason    = list(type = "string"),
    supporting_phrase = list(type = "string")),
  required = list("include", "confidence", "primary_reason", "supporting_phrase"))

.classify_one_schema <- function(model, prompt_text, seed = 42L) {
  body <- list(model = model, prompt = prompt_text, format = RESPONSE_SCHEMA,
               stream = FALSE, options = list(temperature = 0, seed = seed))
  r <- tryCatch(
    httr::POST(OLLAMA_ENDPOINT, body = jsonlite::toJSON(body, auto_unbox = TRUE),
               encode = "raw", httr::content_type_json(), httr::timeout(300)),
    error = function(e) NULL)
  if (is.null(r) || httr::status_code(r) != 200)
    return(list(ok = FALSE, error = sprintf("HTTP %s",
      if (is.null(r)) "no-response" else httr::status_code(r))))
  raw    <- httr::content(r, "parsed", "application/json")$response
  parsed <- tryCatch(jsonlite::fromJSON(raw), error = function(e) NULL)
  if (is.null(parsed) || !all(c("include", "confidence", "primary_reason") %in% names(parsed)))
    return(list(ok = FALSE, error = "schema-invalid", raw = raw))
  list(ok = TRUE, include = isTRUE(parsed$include),
       confidence = as.character(parsed$confidence),
       primary_reason = as.character(parsed$primary_reason),
       supporting_phrase = as.character(parsed$supporting_phrase %||% ""), raw = raw)
}

.log <- function(record, path = LOG_PATH) {
  cat(jsonlite::toJSON(c(record, list(when = format(Sys.time()))),
                       auto_unbox = TRUE, null = "null"), "\n",
      file = path, append = TRUE)
}

# ---- Identify the work ----------------------------------------------------
ledger <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::mutate(has_abstract = !is.na(abstract) & nzchar(abstract))
corpus <- ledger |> dplyr::filter(has_abstract)

message("Scanning cache for missing/failed votes across ", NROW(corpus), " records...")
needs <- list()
for (i in seq_len(NROW(corpus))) {
  rid <- corpus$id[i]
  for (model in MODELS) for (run_idx in seq_len(N_RUNS)) {
    p <- .cache_path_inf(model, POLARITY, rid, run_idx, CRITERIA_HASH)
    good <- FALSE
    if (file.exists(p)) {
      x <- tryCatch(jsonlite::read_json(p, simplifyVector = TRUE), error = function(e) NULL)
      good <- !is.null(x) && isTRUE(x$ok)
    }
    if (!good) needs[[length(needs) + 1]] <-
      list(row = i, id = rid, model = model, run_idx = run_idx, path = p)
  }
}
message("Votes needing repair: ", length(needs),
        "  across ", length(unique(vapply(needs, `[[`, "", "id"))), " records")

.log(list(event = "repair_start", n_votes = length(needs),
          n_records = length(unique(vapply(needs, `[[`, "", "id"))),
          models = MODELS, polarity = POLARITY, criteria_hash = CRITERIA_HASH))

# ---- Repair loop ----------------------------------------------------------
n_ok <- 0L; n_fail <- 0L; t0 <- Sys.time()
for (k in seq_along(needs)) {
  w   <- needs[[k]]
  rec <- corpus[w$row, ]

  # Preserve whatever was there before overwriting it.
  if (file.exists(w$path)) {
    old <- tryCatch(jsonlite::read_json(w$path, simplifyVector = TRUE), error = function(e) NULL)
    .log(list(event = "quarantined_original", record_id = w$id, model = w$model,
              run_idx = w$run_idx, error = old$error %||% "unparseable",
              raw = substr(old$raw %||% "", 1, 2000)), path = QUARANTINE)
  }

  prompt_text <- .prompt_affirmative(CRITERIA_TEXT, rec$title, rec$abstract)
  res <- NULL
  for (attempt in seq_len(MAX_TRIES)) {
    res <- .classify_one_schema(w$model, prompt_text, seed = 42L + w$run_idx)
    if (isTRUE(res$ok)) break
    Sys.sleep(2 * attempt)   # only useful for transient HTTP failures
  }

  if (isTRUE(res$ok)) {
    res$model <- w$model; res$polarity <- POLARITY; res$record_id <- w$id
    res$run_idx <- w$run_idx; res$when <- format(Sys.time())
    res$repair <- "schema-constrained"
    jsonlite::write_json(res, w$path, auto_unbox = TRUE, null = "null")
    n_ok <- n_ok + 1L
  } else {
    n_fail <- n_fail + 1L
    .log(list(event = "repair_unrecoverable", record_id = w$id, model = w$model,
              run_idx = w$run_idx, error = res$error %||% "unknown",
              abstract_chars = nchar(rec$abstract %||% "")))
  }

  if (k %% 25 == 0 || k == length(needs)) {
    el <- as.numeric(Sys.time() - t0, units = "secs")
    message(sprintf("  [%d/%d] repaired %d, unrecoverable %d, elapsed %.1f min (ETA %.1f min)",
                    k, length(needs), n_ok, n_fail, el / 60,
                    (length(needs) - k) * (el / k) / 60))
    .log(list(event = "repair_checkpoint", done = k, total = length(needs),
              repaired = n_ok, unrecoverable = n_fail,
              elapsed_min = round(el / 60, 1)))
  }
}

.log(list(event = "repair_done", repaired = n_ok, unrecoverable = n_fail,
          elapsed_min = round(as.numeric(Sys.time() - t0, units = "mins"), 1)))
cat(sprintf("\n=== REPAIR DONE. recovered %d votes, %d unrecoverable ===\n", n_ok, n_fail))
