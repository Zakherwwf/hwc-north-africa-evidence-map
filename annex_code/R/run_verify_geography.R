# ---------------------------------------------------------------------------
# run_verify_geography.R — Module 06 stage 0: geographic verification.
#
# WHY THIS EXISTS
# Module 04b screened on eligibility as a whole and returned 550 includes.
# Spot-extraction in Module 06 surfaced out-of-region records (Israel's Hula
# Valley, elephants, European brown bear, US feral swine), and a string audit
# of all 550 found 59.5% with no North Africa term anywhere in title+abstract
# and 13.8% naming another country while naming none of ours.
#
# This is not a classifier bug. Specificity was 0.926 with benchmark precision
# 0.650; at a true prevalence near 0.5% even strong specificity yields many
# false positives. The union decision rule, chosen to protect recall, makes it
# worse by construction.
#
# Module 07 counts studies per country, per species, per conflict type. Those
# counts are only meaningful over records actually situated in the five
# countries, so geography must be verified BEFORE the map is built and before
# the expensive full-text extraction runs.
#
# This pass asks one narrow question per record against title+abstract, so it
# covers all 550 including the 264 with no retrievable full text. It does NOT
# re-litigate eligibility -- only location.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(jsonlite); library(httr); library(digest)
})
readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "extract.R"))

GEO_MODEL <- "gemma4:e4b"
GEO_CTX   <- 8192L
STAMP     <- format(Sys.Date(), "%Y%m%d")
LOG_PATH  <- here::here(DIR_LOGS, sprintf("06_geo_%s.jsonl", STAMP))
OUT_PATH  <- here::here(DIR_DERIVED, "geography_verification.rds")
OUT_CSV   <- here::here(DIR_DERIVED, "geography_verification.csv")

GEO_SCHEMA <- list(
  type = "object",
  properties = list(
    study_country = list(type = "string",
      enum = list("Tunisia","Algeria","Morocco","Libya","Egypt",
                  "multiple North African","other country","not stated")),
    in_scope = list(type = "boolean"),
    evidence_quote = list(type = "string")),
  required = list("study_country","in_scope","evidence_quote"))

.geo_prompt <- function(title, abstract) sprintf(
'Determine WHERE the study described below was carried out. Answer only from
the text; do not use outside knowledge and do not guess.

The evidence map covers only these five countries: Tunisia, Algeria, Morocco,
Libya, Egypt -- including their coastal and marine waters.

study_country: the country the STUDY IS ABOUT (not the authors\' affiliation).
  Use "multiple North African" if it spans several of the five.
  Use "other country" if it is about anywhere else (including Israel, Sudan,
  sub-Saharan Africa, Europe, Asia, the Americas).
  Use "not stated" if the text genuinely does not say.
in_scope: true ONLY if the study is located in one or more of the five
  countries or their waters. A study of the wider Mediterranean counts as
  in_scope only if the text ties it to North African waters.
evidence_quote: a VERBATIM quote naming the place. Empty string if none.

Title: %s
Abstract: %s', title, abstract %||% "")

.log <- function(x) cat(jsonlite::toJSON(c(x, list(when = format(Sys.time()))),
                        auto_unbox = TRUE, null = "null"), "\n",
                        file = LOG_PATH, append = TRUE)

preds <- readRDS(here::here(DIR_DERIVED, "classification_predictions.rds"))
ledg  <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |> dplyr::distinct(id, .keep_all = TRUE)
work  <- preds |> dplyr::filter(status == "include") |> dplyr::distinct(id) |>
  dplyr::inner_join(ledg, by = "id")
message("Verifying geography for ", NROW(work), " included records")
.log(list(event = "run_start", n = NROW(work), model = GEO_MODEL))

CACHE <- here::here("cache", "geography"); dir.create(CACHE, showWarnings = FALSE, recursive = TRUE)

rows <- vector("list", NROW(work)); t0 <- Sys.time()
for (i in seq_len(NROW(work))) {
  rec <- work[i, ]
  key <- digest::digest(list(GEO_MODEL, rec$id, rec$title, rec$abstract), algo = "xxhash64")
  cp  <- file.path(CACHE, paste0(key, ".json"))

  if (file.exists(cp)) {
    x <- tryCatch(jsonlite::read_json(cp, simplifyVector = TRUE), error = function(e) NULL)
  } else {
    body <- list(model = GEO_MODEL, prompt = .geo_prompt(rec$title, rec$abstract),
                 format = GEO_SCHEMA, stream = FALSE,
                 options = list(temperature = 0, seed = 42L, num_ctx = GEO_CTX))
    r <- tryCatch(httr::POST(OLLAMA_ENDPOINT, body = jsonlite::toJSON(body, auto_unbox = TRUE),
                             encode = "raw", httr::content_type_json(), httr::timeout(300)),
                  error = function(e) NULL)
    x <- if (is.null(r) || httr::status_code(r) != 200) list(ok = FALSE) else {
      p <- tryCatch(jsonlite::fromJSON(httr::content(r, "parsed", "application/json")$response),
                    error = function(e) NULL)
      if (is.null(p)) list(ok = FALSE) else c(list(ok = TRUE), p)
    }
    jsonlite::write_json(x, cp, auto_unbox = TRUE, null = "null")
  }

  ok <- isTRUE(x$ok)
  rows[[i]] <- tibble::tibble(
    id = rec$id, title = rec$title,
    cell_country = sub("^[a-z]+_[a-z]+_", "", rec$cell_id),
    study_country = if (ok) as.character(x$study_country) else NA_character_,
    in_scope      = if (ok) isTRUE(x$in_scope) else NA,
    quote         = if (ok) as.character(x$evidence_quote) else NA_character_,
    quote_grounded = if (ok) ground_quote(x$evidence_quote,
                       paste(rec$title, rec$abstract)) else NA,
    verified = ok)

  if (i %% 25 == 0 || i == NROW(work)) {
    el <- as.numeric(Sys.time() - t0, units = "mins")
    message(sprintf("  [%d/%d] %.1f min, ETA %.1f min", i, NROW(work), el,
                    (NROW(work) - i) * (el / i)))
  }
}

geo <- dplyr::bind_rows(rows)
saveRDS(geo, OUT_PATH)
readr::write_csv(geo |> dplyr::select(-quote), OUT_CSV)

cat("\n=== GEOGRAPHIC VERIFICATION ===\n")
print(geo |> dplyr::count(study_country, sort = TRUE))
cat(sprintf("\nin_scope TRUE : %d\nin_scope FALSE: %d\nunverified    : %d\n",
            sum(geo$in_scope %in% TRUE), sum(geo$in_scope %in% FALSE), sum(!geo$verified)))
cat(sprintf("\nEstimated screening precision: %.1f%% (%d of %d)\n",
            100 * sum(geo$in_scope %in% TRUE) / NROW(geo), sum(geo$in_scope %in% TRUE), NROW(geo)))
cat("\n=== search cell vs verified location (leakage per cell) ===\n")
print(geo |> dplyr::group_by(cell_country) |>
      dplyr::summarise(n = dplyr::n(), in_scope = sum(in_scope %in% TRUE),
                       pct = round(100 * sum(in_scope %in% TRUE) / dplyr::n(), 1),
                       .groups = "drop") |> dplyr::arrange(dplyr::desc(n)))
.log(list(event = "run_done", in_scope = sum(geo$in_scope %in% TRUE), n = NROW(geo)))
cat(sprintf("\nWrote %s\n", OUT_PATH))
