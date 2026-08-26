# ---------------------------------------------------------------------------
# run_country_attribution.R — Module 07 prerequisite: which of the five
# countries each analytic study actually covers.
#
# WHY A SECOND GEOGRAPHY PASS
# run_verify_geography.R answered one question -- is this study in scope --
# with a single-valued `study_country`. That was the right schema for a gate
# but the wrong one for a map: 183 of the 262 analytic records came back
# "multiple North African", which is true and useless. Studies-per-country is
# the headline of Module 07 and it cannot be computed from a label that
# collapses four countries into one bucket.
#
# This pass asks the multi-label question instead: one boolean per country,
# so a study of the Maghreb can count toward Morocco, Algeria AND Tunisia.
#
# COUNTS ARE THEREFORE NOT MUTUALLY EXCLUSIVE. A study covering three
# countries contributes to three cells and the column sums exceed the number
# of studies. Module 07 prints the denominator beside every count and reports
# both this multi-label count and the count of studies that are ABOUT one
# country alone -- the two answer different questions and the second is the
# stricter one.
#
# The string-match column is a corroboration check, not the answer: a paper
# can name Tunisia in its literature review without being about Tunisia,
# which is precisely the failure mode the tiering exists to expose.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr)
  library(jsonlite); library(httr); library(digest); library(tidyr)
})
readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "extract.R"))

ATTR_MODEL <- "gemma4:e4b"
ATTR_CTX   <- 8192L
CACHE      <- here::here("cache", "country_attribution")
OUT_PATH   <- here::here(DIR_DERIVED, "country_attribution.rds")
OUT_CSV    <- here::here(DIR_DERIVED, "country_attribution.csv")
LOG_PATH   <- here::here(DIR_LOGS, sprintf("07_country_%s.jsonl", format(Sys.Date(), "%Y%m%d")))

CKEYS <- c(Tunisia = "tunisia", Algeria = "algeria", Morocco = "morocco",
           Libya = "libya", Egypt = "egypt")

# Terms used only for the corroboration column, never for attribution.
CTERMS <- list(
  Tunisia = c("tunisia", "tunisian", "tunis", "ichkeul", "kroumirie", "gulf of gab"),
  Algeria = c("algeria", "algerian", "djurdjura", "kabylie", "kabylia"),
  Morocco = c("morocco", "moroccan", "atlas mountain", "rif ", "souss", "agadir"),
  Libya   = c("libya", "libyan", "cyrenaica", "tripolitania", "fezzan"),
  Egypt   = c("egypt", "egyptian", "nile", "sinai", "lake nasser", "bardawil"))

ATTR_SCHEMA <- list(
  type = "object",
  properties = c(
    setNames(lapply(CKEYS, function(k) list(type = "boolean")), unname(CKEYS)),
    list(evidence_quote = list(type = "string"))),
  required = as.list(c(unname(CKEYS), "evidence_quote")))

.attr_prompt <- function(title, abstract) sprintf(
'For each of the five countries below, say whether the STUDY described here
was carried out in that country, or covers it as one of its study areas.

Answer only from the text. Do not use outside knowledge and do not guess.

Mark a country true ONLY if the study itself concerns that country, including
its coastal and marine waters. Mark it false if the country is merely
mentioned in passing, cited from other work, or named only as part of a
region without the study covering it.

A study may be true for several countries at once. A regional study of North
Africa or the Maghreb that explicitly covers particular countries should be
true for each of those countries.

evidence_quote: a VERBATIM quote from the text naming the study location.
Empty string if the text names none.

Title: %s
Abstract: %s', title, if (is.na(abstract)) "" else abstract)

.log <- function(x) cat(jsonlite::toJSON(c(x, list(when = format(Sys.time()))),
                        auto_unbox = TRUE, null = "null"), "\n",
                        file = LOG_PATH, append = TRUE)

tiers <- readRDS(here::here(DIR_DERIVED, "geography_tiers.rds"))
ledg  <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::distinct(id, .keep_all = TRUE)

work <- tiers |> dplyr::filter(analytic) |>
  dplyr::select(id, title, tier, study_country) |>
  dplyr::left_join(ledg |> dplyr::select(id, abstract, publication_year, cell_id),
                   by = "id")

message(sprintf("Attributing countries for %d analytic records", NROW(work)))
.log(list(event = "run_start", n = NROW(work), model = ATTR_MODEL))
dir.create(CACHE, showWarnings = FALSE, recursive = TRUE)

rows <- vector("list", NROW(work)); t0 <- Sys.time(); n_err <- 0L
for (i in seq_len(NROW(work))) {
  rec <- work[i, ]
  ta  <- paste(rec$title, dplyr::coalesce(rec$abstract, ""))
  key <- digest::digest(list(ATTR_MODEL, "v1", rec$id, ta), algo = "xxhash64")
  cp  <- file.path(CACHE, paste0(key, ".json"))

  if (file.exists(cp)) {
    x <- tryCatch(jsonlite::read_json(cp, simplifyVector = TRUE), error = function(e) NULL)
  } else {
    body <- list(model = ATTR_MODEL, prompt = .attr_prompt(rec$title, rec$abstract),
                 format = ATTR_SCHEMA, stream = FALSE,
                 options = list(temperature = 0, seed = OLLAMA_SEED, num_ctx = ATTR_CTX))
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
  if (!ok) { n_err <- n_err + 1L; .log(list(event = "call_failed", id = rec$id)) }
  vals <- vapply(unname(CKEYS), function(k) if (ok) isTRUE(x[[k]]) else NA, logical(1))
  rows[[i]] <- tibble::tibble(
    id = rec$id, title = rec$title, tier = rec$tier,
    study_country_single = rec$study_country,
    publication_year = rec$publication_year,
    !!!setNames(as.list(vals), names(CKEYS)),
    quote = if (ok) as.character(x$evidence_quote) else NA_character_,
    quote_grounded = if (ok) ground_quote(x$evidence_quote, ta) else NA,
    verified = ok,
    ta = tolower(ta))

  if (i %% 25 == 0 || i == NROW(work)) {
    el <- as.numeric(Sys.time() - t0, units = "mins")
    message(sprintf("  [%d/%d] %.1f min, ETA %.1f min, %d errors",
                    i, NROW(work), el, (NROW(work) - i) * (el / i), n_err))
  }
}

attr <- dplyr::bind_rows(rows)

# Corroboration: does the record's own text name the country the model
# attributed it to? Reported per country, never used to overwrite the model.
for (cn in names(CTERMS))
  attr[[paste0(cn, "_named")]] <- grepl(paste(CTERMS[[cn]], collapse = "|"), attr$ta)

attr$n_countries <- rowSums(attr[names(CKEYS)], na.rm = TRUE)
attr$any_country <- attr$n_countries > 0

saveRDS(attr |> dplyr::select(-ta), OUT_PATH)
readr::write_csv(attr |> dplyr::select(-ta, -quote), OUT_CSV)

cat("\n=== COUNTRY ATTRIBUTION (multi-label, counts not mutually exclusive) ===\n")
counts <- tibble::tibble(
  country = names(CKEYS),
  studies = vapply(names(CKEYS), function(c) sum(attr[[c]] %in% TRUE), integer(1)),
  sole_focus = vapply(names(CKEYS), function(c)
    sum(attr[[c]] %in% TRUE & attr$n_countries == 1), integer(1)),
  text_names_country = vapply(names(CKEYS), function(c)
    sum(attr[[c]] %in% TRUE & attr[[paste0(c, "_named")]]), integer(1))) |>
  dplyr::mutate(corroborated_pct = round(100 * text_names_country / pmax(studies, 1), 1)) |>
  dplyr::arrange(dplyr::desc(studies))
print(as.data.frame(counts))

cat(sprintf("\nAnalytic records: %d\n", NROW(attr)))
cat(sprintf("Attributed to >=1 of the five: %d (%.1f%%)\n",
            sum(attr$any_country), 100 * mean(attr$any_country)))
cat(sprintf("Attributed to NO country: %d -- in scope by the gate but with no\n  country resolvable from title+abstract\n",
            sum(!attr$any_country)))
cat(sprintf("Sum of country cells: %d (exceeds record count because studies span countries)\n",
            sum(counts$studies)))

cat("\n=== number of countries per study ===\n")
print(table(attr$n_countries))

cat("\n=== how the single-label gate maps onto the multi-label result ===\n")
print(attr |> dplyr::count(study_country_single, any_country))

cat("\n=== attribution by geographic confidence tier ===\n")
print(attr |> dplyr::group_by(tier) |>
      dplyr::summarise(n = dplyr::n(), any_country = sum(any_country),
                       mean_countries = round(mean(n_countries), 2),
                       quote_grounded = sum(quote_grounded %in% TRUE), .groups = "drop"))

.log(list(event = "run_done", n = NROW(attr), n_errors = n_err,
          any_country = sum(attr$any_country),
          counts = as.list(setNames(counts$studies, counts$country))))
cat(sprintf("\nWrote %s\n      %s\n", OUT_PATH, OUT_CSV))
sessionInfo()
