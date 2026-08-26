# ---------------------------------------------------------------------------
# run_fetch_authorship.R — Module 06 stage 0c: author names and affiliation
# countries for the analytic set.
#
# WHY A SEPARATE FETCH
# Module 02 cached only the fields the search and screening needed
# (id, doi, title, abstract, year, language, oa, pdf_url, type, container).
# Authorship was never stored. Module 07 reports authorship equity -- the
# share of studies with in-country first and senior authors -- which is one
# of the map's headline equity findings, so the field has to come from
# somewhere. It comes from OpenAlex metadata, not from a model reading the
# paper: affiliation is recorded data, and asking a model to infer it would
# manufacture error where ground truth exists.
#
# COST
# 254 OpenAlex ids + 8 CORE records resolved by DOI, batched 50 per request:
# ~7 requests. At the ~10 credits/request observed in Module 02 that is ~70
# credits against the 8,000 free-tier cap enforced in search.R's .oa_get().
#
# WHAT "IN-COUNTRY" MEANS HERE
# An author counts as in-country if ANY of their affiliations on this work
# sits in one of the five countries. That is deliberately generous: it
# counts a Tunisian author with a joint French post as Tunisian. The
# generous reading makes the equity finding conservative -- if the share is
# low even counting joint appointments, it is genuinely low.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr)
  library(jsonlite); library(httr); library(purrr)
})
readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "search.R"))   # .oa_get, credit guard, hit logging

STAMP     <- format(Sys.Date(), "%Y%m%d")
LOG_PATH  <- here::here(DIR_LOGS, sprintf("06_authorship_%s.jsonl", STAMP))
OUT_PATH  <- here::here(DIR_DERIVED, "authorship.rds")
OUT_CSV   <- here::here(DIR_DERIVED, "authorship.csv")
CACHE_DIR <- here::here("cache", "authorship")
BATCH     <- 50L

NA_CODES <- c(TN = "Tunisia", DZ = "Algeria", MA = "Morocco",
              LY = "Libya",   EG = "Egypt")

.log <- function(x) cat(jsonlite::toJSON(c(x, list(when = format(Sys.time()))),
                        auto_unbox = TRUE, null = "null"), "\n",
                        file = LOG_PATH, append = TRUE)

tiers <- readRDS(here::here(DIR_DERIVED, "geography_tiers.rds"))
ledg  <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::distinct(id, .keep_all = TRUE)

work <- tiers |> dplyr::filter(analytic) |> dplyr::select(id, title) |>
  dplyr::left_join(ledg |> dplyr::select(id, doi, source), by = "id") |>
  dplyr::mutate(oa_id = dplyr::if_else(grepl("openalex\\.org/W", id),
                                       sub("^.*/", "", id), NA_character_),
                doi_clean = sub("^https?://(dx\\.)?doi\\.org/", "", tolower(doi)))

message(sprintf("Analytic set %d: %d by OpenAlex id, %d by DOI, %d unresolvable",
                NROW(work), sum(!is.na(work$oa_id)),
                sum(is.na(work$oa_id) & !is.na(work$doi_clean)),
                sum(is.na(work$oa_id) & is.na(work$doi_clean))))

dir.create(CACHE_DIR, showWarnings = FALSE, recursive = TRUE)

SELECT <- "id,doi,display_name,publication_year,authorships,primary_location,type"

.fetch_batch <- function(values, filter_field) {
  key <- digest::digest(list(filter_field, values, SELECT), algo = "xxhash64")
  cp  <- file.path(CACHE_DIR, paste0(key, ".rds"))
  if (file.exists(cp)) return(readRDS(cp))
  url <- sprintf("%s/works?filter=%s:%s&per-page=%d&select=%s",
                 OPENALEX_BASE, filter_field,
                 utils::URLencode(paste(values, collapse = "|"), reserved = TRUE),
                 BATCH, SELECT)
  res <- .oa_get(url)
  if (is.null(res)) {
    .log(list(event = "batch_failed", filter = filter_field, n = length(values)))
    return(NULL)
  }
  saveRDS(res$results, cp)
  .log(list(event = "batch_ok", filter = filter_field, n = length(values),
            returned = length(res$results)))
  res$results
}

.chunks <- function(x, n) split(x, ceiling(seq_along(x) / n))

results <- list()

oa_ids <- na.omit(work$oa_id)
for (ch in .chunks(oa_ids, BATCH)) {
  r <- .fetch_batch(ch, "openalex_id")
  if (!is.null(r)) results <- c(results, r)
  message(sprintf("  openalex_id batch: %d requested, %d cumulative results",
                  length(ch), length(results)))
}

dois <- work$doi_clean[is.na(work$oa_id) & !is.na(work$doi_clean)]
for (ch in .chunks(dois, BATCH)) {
  r <- .fetch_batch(ch, "doi")
  if (!is.null(r)) results <- c(results, r)
  message(sprintf("  doi batch: %d requested, %d cumulative results",
                  length(ch), length(results)))
}

if (!length(results)) stop("No authorship results returned; check OPENALEX_API_KEY.")

# ---- Parse -----------------------------------------------------------------

.countries_of <- function(a) {
  cs <- unlist(a$countries %||% list())
  if (!length(cs))
    cs <- unlist(lapply(a$institutions %||% list(), function(i) i$country_code %||% NULL))
  unique(toupper(as.character(cs[!is.na(cs) & nzchar(cs)])))
}

.incountry <- function(x) vapply(x, function(v) {
  if (is.na(v) || !nzchar(v)) return(NA)
  any(strsplit(v, "\\|")[[1]] %in% names(NA_CODES))
}, logical(1), USE.NAMES = FALSE)

auth <- purrr::map_dfr(results, function(w) {
  as <- w$authorships %||% list()
  base <- tibble::tibble(
    oa_id     = sub("^.*/", "", w$id %||% NA_character_),
    doi_clean = sub("^https?://(dx\\.)?doi\\.org/", "", tolower(w$doi %||% NA_character_)))
  # OpenAlex carries works with no authorship array at all (paratext, some
  # book chapters). They are not an error and not zero-author papers -- the
  # metadata is simply absent, so every author field stays NA and the record
  # drops out of the equity denominator rather than counting as "no
  # in-country author".
  if (!length(as))
    return(dplyr::bind_cols(base, tibble::tibble(
      n_authors = NA_integer_, authors = NA_character_, journal_oa = NA_character_,
      first_author_countries = NA_character_, last_author_countries = NA_character_,
      author_countries = NA_character_, n_countries = NA_integer_)))

  nms <- vapply(as, function(a) (a$author$display_name %||% NA_character_)[1], character(1))
  ctry <- lapply(as, .countries_of)
  pos  <- vapply(as, function(a) (a$author_position %||% NA_character_)[1], character(1))
  first_i <- which(pos == "first"); last_i <- which(pos == "last")
  if (!length(first_i)) first_i <- 1L
  if (!length(last_i))  last_i  <- length(as)
  all_c <- unique(unlist(ctry))
  dplyr::bind_cols(base, tibble::tibble(
    n_authors    = length(as),
    authors      = if (any(!is.na(nms))) paste(nms[!is.na(nms)], collapse = "; ") else NA_character_,
    journal_oa   = (w$primary_location$source$display_name %||% NA_character_)[1],
    first_author_countries = paste(ctry[[first_i[1]]], collapse = "|"),
    last_author_countries  = paste(ctry[[last_i[1]]],  collapse = "|"),
    author_countries       = paste(all_c, collapse = "|"),
    n_countries  = length(all_c)))
}) |>
  dplyr::mutate(
    # "" means OpenAlex listed the author but recorded no affiliation for
    # them. That is missing data, not evidence of a foreign affiliation, so
    # it becomes NA and the record leaves the equity denominator.
    dplyr::across(dplyr::all_of(c("first_author_countries", "last_author_countries",
                                  "author_countries")), ~ dplyr::na_if(.x, "")),
    first_incountry = .incountry(first_author_countries),
    last_incountry  = .incountry(last_author_countries),
    any_incountry   = .incountry(author_countries))

# Join on OpenAlex id where we have one, then fill the CORE records from the
# same result set matched by DOI. coalesce() rather than a second join keeps
# one row per analytic record, which the row-count assertion below enforces.
AUTH_COLS <- setdiff(names(auth), c("oa_id", "doi_clean"))

by_oa  <- auth |> dplyr::filter(!is.na(oa_id))    |> dplyr::distinct(oa_id, .keep_all = TRUE)
by_doi <- auth |> dplyr::filter(!is.na(doi_clean)) |> dplyr::distinct(doi_clean, .keep_all = TRUE)

out <- work |>
  dplyr::left_join(by_oa  |> dplyr::select(oa_id, dplyr::all_of(AUTH_COLS)),
                   by = "oa_id") |>
  dplyr::left_join(by_doi |> dplyr::select(doi_clean, dplyr::all_of(AUTH_COLS)),
                   by = "doi_clean", suffix = c("", ".doi"))

for (cl in AUTH_COLS)
  out[[cl]] <- dplyr::coalesce(out[[cl]], out[[paste0(cl, ".doi")]])
out <- out |> dplyr::select(-dplyr::ends_with(".doi"))

stopifnot(NROW(out) == NROW(work))

saveRDS(out, OUT_PATH)
readr::write_csv(out |> dplyr::select(-title), OUT_CSV)

cat("\n=== AUTHORSHIP COVERAGE ===\n")
cat(sprintf("Records with authorship: %d of %d (%.1f%%)\n",
            sum(!is.na(out$n_authors)), NROW(out),
            100 * mean(!is.na(out$n_authors))))
cat(sprintf("Records with any affiliation country: %d\n", sum(!is.na(out$author_countries))))
cat("\n=== in-country authorship (of records with affiliation data) ===\n")
cov <- out |> dplyr::filter(!is.na(author_countries))
.share <- function(lab, v) {
  k <- sum(v %in% TRUE); d <- sum(!is.na(v))
  cat(sprintf("%s: %d / %d (%.1f%%)%s\n", lab, k, d, 100 * k / d,
              if (d < NROW(cov)) sprintf("  [%d without affiliation data]", NROW(cov) - d) else ""))
}
.share("first author in-country ", cov$first_incountry)
.share("senior author in-country", cov$last_incountry)
.share("any author in-country   ", cov$any_incountry)
cat("\n=== most frequent affiliation countries ===\n")
print(sort(table(unlist(strsplit(cov$author_countries, "\\|"))), decreasing = TRUE)[1:15])

.log(list(event = "run_done", n = NROW(out), with_authorship = sum(!is.na(out$n_authors)),
          with_countries = sum(!is.na(out$author_countries)),
          first_incountry = sum(cov$first_incountry %in% TRUE),
          last_incountry = sum(cov$last_incountry %in% TRUE),
          credits_used = .oa_env$credits_used))
cat(sprintf("\nOpenAlex credits used this run: %d (cap %d)\n",
            .oa_env$credits_used, .OPENALEX_CREDIT_CAP))
cat(sprintf("Wrote %s\n      %s\n", OUT_PATH, OUT_CSV))
sessionInfo()
