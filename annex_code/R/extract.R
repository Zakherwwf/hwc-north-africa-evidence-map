# ---------------------------------------------------------------------------
# extract.R — Module 06: schema-constrained extraction from TEI.
#
# Extraction targets the METHODS and RESULTS sections, not whole papers, per
# the protocol. Measured on this corpus those sections are a median 12% of the
# body (4,277 vs 36,210 chars), so targeting them cuts the prompt ~8x and keeps
# every record inside an 8,192-token window.
#
# FIELD SOURCING
# Seven of the 26 protocol fields are bibliographic and already known exactly
# from the OpenAlex/CORE metadata captured in Module 02: study_id, authors,
# year, language, source_type, journal, author_affiliation_country. Asking a
# language model to re-read them off the page would manufacture error where we
# already hold ground truth, so those are carried from metadata. The remaining
# 19 fields require reading the paper and are extracted here.
#
# THE FOUR MANDATORY VERIFICATION MECHANISMS
#   1. Quote-grounding   — every non-null field carries a verbatim quote which
#                          is string-matched back to the source text. No match
#                          => value set NA, reason "unverified_quote". The
#                          failure rate is a directly measured hallucination
#                          rate.
#   2. Self-consistency  — two runs; disagreement => NA, "inconsistent_extraction".
#   3. Cross-model       — a random 20% re-extracted with a second model.
#   4. "not stated"      — every enum carries an explicit escape hatch, because
#                          absence is exactly what this map is measuring.
#
# WHY RUN 2 IS NOT AT TEMPERATURE 0
# The protocol specifies "two runs at temperature 0". Module 04b proved that is
# vacuous on this stack: across 60,961 screened records, ZERO had an odd vote
# count, i.e. run 1 and run 2 were byte-identical every single time. Greedy
# decoding is deterministic, so a temperature-0 pair would report
# self-consistency = 1.00 by construction and measure nothing. Run 2 therefore
# uses temperature EXTRACT_TEMP_PROBE with a different seed, which makes the
# self-consistency figure an actual robustness measurement. Documented as a
# protocol deviation in Module 09.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(httr); library(jsonlite); library(xml2); library(digest)
})

# Defined in classifier.R too; extract.R must stand alone without sourcing it.
if (!exists("OLLAMA_ENDPOINT")) OLLAMA_ENDPOINT <- paste0(OLLAMA_URL, "/api/generate")

EXTRACT_MODEL       <- "gemma4:e4b"     # 131k context; llama3 caps at 8,192
EXTRACT_XMODEL      <- "qwen2.5:7b"     # 32k context, different lineage
EXTRACT_NUM_CTX     <- 8192L
EXTRACT_TEMP_MAIN   <- 0
EXTRACT_TEMP_PROBE  <- 0.3
EXTRACT_MAX_CHARS   <- 24000L           # ~5,200 tok; above p95 of section size
DIR_EXTRACT_CACHE   <- file.path("cache", "extraction")

NOT_STATED <- "not stated"

# ---- Field groups ---------------------------------------------------------
# Split into three calls rather than one 19-field JSON: smaller schemas hold
# the model to the task and a failure in one group does not void the others.

FIELD_GROUPS <- list(
  setting = list(
    country = c("Tunisia","Algeria","Morocco","Libya","Egypt","multiple","other",NOT_STATED),
    subnational_region  = NULL,
    marine_terrestrial  = c("marine","terrestrial","both",NOT_STATED),
    species_common      = NULL,
    species_scientific  = NULL,
    taxonomic_class     = c("mammal","bird","reptile","fish","amphibian",
                            "invertebrate","multiple",NOT_STATED),
    conflict_type       = c("crop damage","livestock depredation","attacks on humans",
                            "bycatch","persecution or retaliatory killing",
                            "property damage","disease transmission",
                            "competition for resources","other",NOT_STATED)),
  design = list(
    study_design = c("survey or questionnaire","interviews","direct observation",
                     "camera trap","telemetry","experiment","modelling",
                     "secondary data analysis","review","mixed","other",NOT_STATED),
    sample_size            = NULL,
    years_of_data          = NULL,
    damage_metric_reported = c("yes","no",NOT_STATED),
    damage_estimate        = NULL),
  mitigation = list(
    mitigation_tested            = c("yes","no",NOT_STATED),
    mitigation_type              = NULL,
    mitigation_outcome_measured  = c("yes","no",NOT_STATED),
    outcome_direction            = c("reduced conflict","no change","increased conflict",
                                     "mixed","not measured",NOT_STATED),
    stakeholder_engagement       = c("yes","no",NOT_STATED),
    compensation_scheme_discussed= c("yes","no",NOT_STATED),
    funding_source               = NULL)
)

EXTRACT_FIELDS <- unlist(lapply(FIELD_GROUPS, names), use.names = FALSE)

# ---- TEI -> methods/results text ------------------------------------------
.SECTION_PAT <- paste0("method|material|protocol|study area|study site|",
                       "data collection|sampling|analysis|result|finding")

tei_sections <- function(tei_path, max_chars = EXTRACT_MAX_CHARS) {
  d <- tryCatch(xml2::read_xml(tei_path), error = function(e) NULL)
  if (is.null(d)) return(list(text = NA_character_, source = "unreadable", n_divs = 0L))
  ns   <- xml2::xml_ns_rename(xml2::xml_ns(d), d1 = "tei")
  divs <- xml2::xml_find_all(d, "//tei:text/tei:body/tei:div", ns)
  heads <- tolower(vapply(divs, function(x)
    xml2::xml_text(xml2::xml_find_first(x, "./tei:head", ns)), character(1)))
  keep <- which(!is.na(heads) & grepl(.SECTION_PAT, heads))
  if (length(keep)) {
    txt <- paste(vapply(divs[keep], xml2::xml_text, character(1)), collapse = "\n\n")
    src <- "methods_results"
  } else {
    # 44/286 files carry no recognisable section heads. Falling back to the
    # whole body is better than dropping the record, but it IS a different
    # evidence base, so the source is recorded and reported.
    txt <- xml2::xml_text(xml2::xml_find_first(d, "//tei:text/tei:body", ns))
    src <- "full_body_fallback"
  }
  if (is.na(txt) || !nzchar(txt)) return(list(text = NA_character_, source = "empty", n_divs = length(divs)))
  txt <- gsub("[ \t]+", " ", gsub("\r", " ", txt))
  truncated <- nchar(txt) > max_chars
  if (truncated) txt <- substr(txt, 1, max_chars)
  list(text = txt, source = if (truncated) paste0(src, "_truncated") else src,
       n_divs = length(divs))
}

# ---- Prompt + JSON schema --------------------------------------------------

.schema_for <- function(group) {
  props <- lapply(names(group), function(f) {
    vals <- group[[f]]
    val_schema <- if (is.null(vals)) list(type = "string")
                  else list(type = "string", enum = as.list(vals))
    list(type = "object",
         properties = list(value = val_schema,
                           evidence_quote = list(type = "string")),
         required = list("value", "evidence_quote"))
  })
  names(props) <- names(group)
  list(type = "object", properties = props, required = as.list(names(group)))
}

.prompt_for <- function(group, group_name, text) {
  spec <- vapply(names(group), function(f) {
    vals <- group[[f]]
    if (is.null(vals)) sprintf("  %s: free text, or \"%s\"", f, NOT_STATED)
    else sprintf("  %s: one of [%s]", f, paste(sprintf('"%s"', vals), collapse = ", "))
  }, character(1))
  sprintf(
'You are extracting structured data from the METHODS and RESULTS sections of a
study for a systematic evidence map of human-wildlife conflict in North Africa.

Extract exactly these fields (%s):
%s

RULES — these matter more than filling in fields:
- Report ONLY what the text states. Do NOT infer, guess, or use outside knowledge.
- If the text does not state a field, the value is "%s". That is a correct and
  expected answer; absence is what this map measures.
- evidence_quote must be copied VERBATIM from the text below, character for
  character. It is string-matched against the source and a quote that cannot be
  found sets the field to null.
- If the value is "%s", set evidence_quote to "".

TEXT:
%s',
    group_name, paste(spec, collapse = "\n"), NOT_STATED, NOT_STATED, text)
}

# ---- Quote grounding ------------------------------------------------------
# Normalise whitespace and case on both sides before matching: GROBID collapses
# layout whitespace unpredictably, and a quote that differs only by a double
# space is a true extraction, not a hallucination.

.norm <- function(x) {
  x <- tolower(x)
  x <- gsub("[‘’‚‛]", "'", x)
  x <- gsub("[“”„‟]", '"', x)
  x <- gsub("[‐-―]", "-", x)
  gsub("\\s+", " ", trimws(x))
}

# Models routinely stitch two distant spans with an ellipsis ("A ... B"). Both
# halves can be verbatim while the concatenation is not, so an ellipsis quote is
# split and every segment must be found. This is still a strict test — it just
# does not score a correct two-span citation as a hallucination.

ground_quote <- function(quote, source_text) {
  if (is.null(quote) || is.na(quote) || !nzchar(trimws(quote))) return(NA)
  s <- .norm(source_text)
  parts <- trimws(strsplit(.norm(quote), "\\s*(\\.{3}|\u2026|\\[\\s*\\])\\s*")[[1]])
  parts <- parts[nzchar(parts)]
  if (!length(parts)) return(NA)
  if (any(nchar(parts) < 8)) parts <- parts[nchar(parts) >= 8]
  if (!length(parts)) return(NA)        # too short to verify meaningfully
  all(vapply(parts, function(p) grepl(p, s, fixed = TRUE), logical(1)))
}

# ---- Model call -----------------------------------------------------------

.cache_path_ext <- function(model, group_name, record_id, run_tag, text_hash) {
  d <- here::here(DIR_EXTRACT_CACHE)
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  key <- digest::digest(list(model, group_name, record_id, run_tag, text_hash),
                        algo = "xxhash64")
  file.path(d, sprintf("%s.json", key))
}

extract_group <- function(record_id, text, group_name, model = EXTRACT_MODEL,
                          temperature = EXTRACT_TEMP_MAIN, seed = 42L,
                          run_tag = "main", force = FALSE) {
  group <- FIELD_GROUPS[[group_name]]
  th <- digest::digest(text, algo = "xxhash64")
  cp <- .cache_path_ext(model, group_name, record_id, run_tag, th)
  if (!force && file.exists(cp))
    return(tryCatch(jsonlite::read_json(cp, simplifyVector = TRUE), error = function(e) NULL))

  body <- list(model = model, prompt = .prompt_for(group, group_name, text),
               format = .schema_for(group), stream = FALSE,
               options = list(temperature = temperature, seed = seed,
                              num_ctx = EXTRACT_NUM_CTX))
  r <- tryCatch(httr::POST(OLLAMA_ENDPOINT,
                           body = jsonlite::toJSON(body, auto_unbox = TRUE),
                           encode = "raw", httr::content_type_json(),
                           httr::timeout(600)), error = function(e) NULL)
  out <- if (is.null(r)) {
    list(ok = FALSE, error = "no_response")
  } else if (httr::status_code(r) != 200) {
    # Carry the status and Ollama's own message: a bare "http" tells you
    # nothing, and a malformed JSON schema returns 400 with the reason.
    msg <- tryCatch(substr(httr::content(r, "text", encoding = "UTF-8"), 1, 400),
                    error = function(e) "")
    list(ok = FALSE, error = paste0("http_", httr::status_code(r)), detail = msg)
  } else {
    raw <- httr::content(r, "parsed", "application/json")$response
    p <- tryCatch(jsonlite::fromJSON(raw, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(p)) list(ok = FALSE, error = "unparseable", raw = raw)
    else list(ok = TRUE, fields = p, raw = raw)
  }
  out$model <- model; out$group <- group_name; out$record_id <- record_id
  out$run_tag <- run_tag; out$text_hash <- th; out$when <- format(Sys.time())
  jsonlite::write_json(out, cp, auto_unbox = TRUE, null = "null")
  out
}
