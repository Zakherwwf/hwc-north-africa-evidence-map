# ---------------------------------------------------------------------------
# classifier.R — Ollama JSON-constrained classifier client used by both
# Module 04a (SYNERGY benchmark validation) and Module 04b (real corpus).
#
# The prompt SHAPE is fixed across modules: the classifier receives the
# review's inclusion criteria plus a record's (title, abstract) and must
# return schema-valid JSON. In Module 04a the criteria are the SYNERGY
# dataset's own criteria; in Module 04b they come from R/eligibility.R.
#
# Everything is cached: (model, prompt_polarity, record_id, run_index)
# maps to a JSON file under cache/inference/. A knit reads cache, never
# re-runs inference. This is the reproducibility guarantee.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(httr); library(jsonlite); library(digest)
})

OLLAMA_ENDPOINT <- "http://localhost:11434/api/generate"

# Three prompt polarities per the protocol's polarity-robustness check.
# All three encode logically-equivalent decisions; the classifier's
# behaviour should ideally not depend on which one it sees.

.prompt_affirmative <- function(criteria_text, title, abstract) {
  sprintf(
'You are screening a scientific record for inclusion in a systematic evidence map.

INCLUDE the record if it satisfies ALL of these criteria:
%s

Return ONLY a JSON object with these fields (no prose, no code fences):
  include: true or false
  confidence: "low" | "medium" | "high"
  primary_reason: one short sentence (max 25 words)
  supporting_phrase: a verbatim quote from the title or abstract that justifies the decision (empty string if none)

Record:
Title: %s
Abstract: %s',
    criteria_text, title, abstract %||% "(no abstract available)")
}

.prompt_antonymic <- function(criteria_text, title, abstract) {
  sprintf(
'You are screening a scientific record. Your task is to identify records that FAIL to meet the inclusion criteria.

EXCLUDE the record if it fails ANY of these inclusion criteria:
%s

Return ONLY a JSON object with these fields (no prose, no code fences):
  include: true or false      (true = should be included; false = should be excluded)
  confidence: "low" | "medium" | "high"
  primary_reason: one short sentence (max 25 words)
  supporting_phrase: a verbatim quote from the title or abstract that justifies the decision (empty string if none)

Record:
Title: %s
Abstract: %s',
    criteria_text, title, abstract %||% "(no abstract available)")
}

.prompt_negation <- function(criteria_text, title, abstract) {
  sprintf(
'You are screening a scientific record. Decide whether the record does NOT belong in a systematic evidence map with these inclusion criteria:
%s

Return ONLY a JSON object with these fields (no prose, no code fences):
  include: true or false      (true if the record BELONGS; false if it does NOT belong)
  confidence: "low" | "medium" | "high"
  primary_reason: one short sentence (max 25 words)
  supporting_phrase: a verbatim quote from the title or abstract that justifies the decision (empty string if none)

Record:
Title: %s
Abstract: %s',
    criteria_text, title, abstract %||% "(no abstract available)")
}

PROMPT_POLARITIES <- list(
  affirmative = .prompt_affirmative,
  antonymic   = .prompt_antonymic,
  negation    = .prompt_negation
)

# ---- Ollama call ----------------------------------------------------------

.classify_one <- function(model, prompt_text, seed = 42L) {
  body <- list(
    model   = model,
    prompt  = prompt_text,
    format  = "json",
    stream  = FALSE,
    options = list(temperature = 0, seed = seed)
  )
  r <- tryCatch(
    httr::POST(OLLAMA_ENDPOINT,
               body = jsonlite::toJSON(body, auto_unbox = TRUE),
               encode = "raw",
               httr::content_type_json(),
               httr::timeout(180)),
    error = function(e) NULL)
  if (is.null(r) || httr::status_code(r) != 200) {
    return(list(ok = FALSE, error = sprintf("HTTP %s",
      if (is.null(r)) "no-response" else httr::status_code(r))))
  }
  raw <- httr::content(r, "parsed", "application/json")$response
  parsed <- tryCatch(jsonlite::fromJSON(raw),
                     error = function(e) NULL)
  if (is.null(parsed) || !all(c("include","confidence","primary_reason") %in% names(parsed))) {
    return(list(ok = FALSE, error = "schema-invalid", raw = raw))
  }
  list(ok = TRUE,
       include           = isTRUE(parsed$include),
       confidence        = as.character(parsed$confidence),
       primary_reason    = as.character(parsed$primary_reason),
       supporting_phrase = as.character(parsed$supporting_phrase %||% ""),
       raw               = raw)
}

# ---- Cache-aware ensemble runner -----------------------------------------

.cache_dir_inf <- function() {
  d <- here::here("cache", "inference")
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  d
}

.cache_path_inf <- function(model, polarity, record_id, run_idx, criteria_hash) {
  key <- digest::digest(list(model, polarity, record_id, run_idx, criteria_hash),
                        algo = "xxhash64")
  file.path(.cache_dir_inf(), sprintf("%s.json", key))
}

classify_record <- function(record_id, title, abstract, criteria_text,
                            models, polarity = "affirmative",
                            n_runs = 2L, force = FALSE) {
  fn <- PROMPT_POLARITIES[[polarity]]
  stopifnot(!is.null(fn))
  criteria_hash <- digest::digest(criteria_text, algo = "xxhash64")
  results <- list()
  for (model in models) {
    for (run_idx in seq_len(n_runs)) {
      cache_path <- .cache_path_inf(model, polarity, record_id, run_idx, criteria_hash)
      if (!force && file.exists(cache_path)) {
        res <- jsonlite::read_json(cache_path, simplifyVector = TRUE)
      } else {
        prompt_text <- fn(criteria_text, title, abstract)
        res <- .classify_one(model, prompt_text, seed = 42L + run_idx)
        res$model     <- model
        res$polarity  <- polarity
        res$record_id <- record_id
        res$run_idx   <- run_idx
        res$when      <- format(Sys.time())
        jsonlite::write_json(res, cache_path, auto_unbox = TRUE, null = "null")
      }
      results[[length(results) + 1]] <- res
    }
  }
  results
}

# Ensemble decision: UNION rule — any model in any run says include -> include.
ensemble_decision <- function(results) {
  votes <- vapply(results, function(x) isTRUE(x$ok) && isTRUE(x$include), logical(1))
  any(votes)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (is.character(a) && !nzchar(a))) b else a
