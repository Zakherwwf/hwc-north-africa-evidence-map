# ---------------------------------------------------------------------------
# run_fulltext.R — Module 05 orchestrator.
#
# Retrieves full text for every INCLUDED record from Module 04b, converts to
# TEI via GROBID, and OCRs scans with Apple Vision.
#
# Scope: the 550 records with status == "include". Records in the two
# unscreened strata (104 inference-failed, 4,755 title-only) are out of scope
# here by construction and are reported in Module 09, not silently lost.
#
# Fully resumable: PDFs, OCR text and TEI are cached on disk and skipped if
# already present. Re-running only attempts what previously failed.
#
# The output ledger records a failure_reason for every record that does not
# end with usable TEI. Per the protocol, retrieval failure is a finding about
# access inequality and is broken down by country and language rather than
# reported as a single success rate.
#
#   Rscript R/run_fulltext.R              # all includes
#   Rscript R/run_fulltext.R --limit 25   # smoke test on the first 25
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(jsonlite); library(readr)
})
readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "fulltext.R"))

args    <- commandArgs(trailingOnly = TRUE)
LIMIT   <- if ("--limit" %in% args) as.integer(args[which(args == "--limit") + 1]) else NA_integer_
STAMP   <- format(Sys.Date(), "%Y%m%d")
LOG_PATH  <- here::here(DIR_LOGS, sprintf("05_fulltext_%s.jsonl", STAMP))
OUT_PATH  <- here::here(DIR_DERIVED, "retrieval_ledger.rds")
OUT_CSV   <- here::here(DIR_DERIVED, "retrieval_by_country.csv")

for (d in c(DIR_PDF, DIR_TEI, DIR_OCR))
  dir.create(here::here(d), showWarnings = FALSE, recursive = TRUE)

.log <- function(rec) {
  cat(jsonlite::toJSON(c(rec, list(when = format(Sys.time()))),
                       auto_unbox = TRUE, null = "null"), "\n",
      file = LOG_PATH, append = TRUE)
}

# ---- Preflight: fail loudly rather than produce a ledger of false zeros ----
alive <- tryCatch(httr::content(httr::GET(paste0(GROBID_URL, "/api/isalive"),
                                          httr::timeout(10)), "text", encoding = "UTF-8"),
                  error = function(e) "")
if (!grepl("true", tolower(alive)))
  stop("GROBID is not responding at ", GROBID_URL,
       "\n  Start it with: docker run -d --rm --name grobid -p 8070:8070 lfoppiano/grobid:0.8.1")
message("GROBID alive at ", GROBID_URL)

# ---- Build the work list --------------------------------------------------
preds <- readRDS(here::here(DIR_DERIVED, "classification_predictions.rds"))
ledg  <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::distinct(id, .keep_all = TRUE)     # 5 duplicate rows exist; see Module 03 note

work <- preds |>
  dplyr::filter(status == "include") |>
  dplyr::distinct(id) |>
  dplyr::inner_join(ledg, by = "id") |>
  dplyr::mutate(
    country  = sub("^[a-z]+_[a-z]+_", "", cell_id),
    cell_lang = sub("^[a-z]+_([a-z]+)_.*$", "\\1", cell_id))
# A --limit run is a SMOKE TEST, so it must sample randomly. Taking head(n)
# sorts by id, which clusters DOI prefixes: the first attempt drew 9/12 from
# one publisher and reported a 0% success rate that was pure ordering
# artifact. Seeded so the sample is reproducible.
if (!is.na(LIMIT)) {
  set.seed(42)
  work <- work[sample(NROW(work), min(LIMIT, NROW(work))), ]
}
message(sprintf("Records to retrieve: %d", NROW(work)))

.log(list(event = "run_start", n = NROW(work), grobid = GROBID_URL,
          scanned_char_min = SCANNED_CHAR_MIN))

# ---- Main loop ------------------------------------------------------------
rows <- vector("list", NROW(work)); t0 <- Sys.time()
for (i in seq_len(NROW(work))) {
  rec <- work[i, ]
  sid <- .safe_id(rec$id)
  pdf_path <- here::here(DIR_PDF, paste0(sid, ".pdf"))
  tei_path <- here::here(DIR_TEI, paste0(sid, ".tei.xml"))
  ocr_path <- here::here(DIR_OCR, paste0(sid, ".txt"))

  out <- tibble::tibble(
    id = rec$id, country = rec$country, cell_lang = rec$cell_lang,
    language = rec$language, source = rec$source, year = rec$publication_year,
    is_oa = rec$is_oa, url = NA_character_, url_source = NA_character_,
    http_status = NA_integer_, downloaded = FALSE, n_pages = NA_integer_,
    median_chars = NA_real_, is_scanned = NA, ocr_applied = FALSE,
    tei_ok = FALSE, n_body_chars = NA_integer_, has_methods = NA,
    failure_reason = NA_character_)

  # 1-2. Resolve candidates and download, falling through to the next
  # candidate when a host refuses. A single 403 from a bot-protected
  # publisher must not condemn a record that also has a repository copy.
  if (file.exists(pdf_path) && file.size(pdf_path) > 1024) {
    out$url_source <- "cached"; out$downloaded <- TRUE
  } else {
    cand <- resolve_pdf_urls(rec)
    if (!length(cand$urls)) {
      out$failure_reason <- "no_pdf_url"; rows[[i]] <- out
      .log(list(event = "record", id = rec$id, stage = "resolve", reason = "no_pdf_url"))
      next
    }
    dl <- NULL
    for (k in seq_along(cand$urls)) {
      out$url <- cand$urls[k]; out$url_source <- cand$sources[k]
      dl <- download_pdf(cand$urls[k], pdf_path)
      out$http_status <- dl$status
      if (dl$ok) break
      .log(list(event = "candidate_failed", id = rec$id, url = cand$urls[k],
                reason = dl$reason))
    }
    if (!isTRUE(dl$ok)) {
      # If every remaining candidate was a bot-protected publisher, say so
      # explicitly -- that is an access finding, not a generic HTTP error.
      out$failure_reason <- if (all(vapply(cand$urls, .is_blocked, logical(1))))
        "publisher_blocked" else dl$reason
      rows[[i]] <- out
      .log(list(event = "record", id = rec$id, stage = "download",
                reason = out$failure_reason, n_candidates = length(cand$urls)))
      next
    }
    out$downloaded <- TRUE
  }

  # 3. Text layer
  ins <- inspect_pdf(pdf_path)
  out$n_pages <- ins$n_pages; out$median_chars <- ins$median_chars
  out$is_scanned <- ins$is_scanned
  if (!ins$ok) {
    out$failure_reason <- ins$reason; rows[[i]] <- out
    .log(list(event = "record", id = rec$id, stage = "inspect", reason = ins$reason))
    next
  }

  # 4. OCR scans. GROBID still runs afterwards: it handles the structure,
  #    while the OCR text is kept as a fallback body for Module 06.
  if (isTRUE(ins$is_scanned)) {
    o <- ocr_pdf(pdf_path, ocr_path)
    out$ocr_applied <- isTRUE(o$ok)
    .log(list(event = "record", id = rec$id, stage = "ocr", reason = o$reason))
  }

  # 5. GROBID -> TEI
  g <- grobid_tei(pdf_path, tei_path)
  if (!g$ok) {
    out$failure_reason <- g$reason; rows[[i]] <- out
    .log(list(event = "record", id = rec$id, stage = "grobid", reason = g$reason))
    next
  }
  s <- tei_summary(tei_path)
  out$tei_ok <- s$tei_ok; out$n_body_chars <- s$n_body_chars; out$has_methods <- s$has_methods
  if (!isTRUE(s$tei_ok)) out$failure_reason <- "tei_unparseable"
  rows[[i]] <- out
  .log(list(event = "record", id = rec$id, stage = "done", tei_ok = s$tei_ok,
            n_body_chars = s$n_body_chars, scanned = ins$is_scanned))

  if (i %% 10 == 0 || i == NROW(work)) {
    el <- as.numeric(Sys.time() - t0, units = "mins")
    message(sprintf("  [%d/%d] %.1f min elapsed, ETA %.1f min",
                    i, NROW(work), el, (NROW(work) - i) * (el / i)))
  }
}

ret <- dplyr::bind_rows(rows)
saveRDS(ret, OUT_PATH)

# ---- Reporting: by country, then by language ------------------------------
by_country <- ret |>
  dplyr::group_by(country) |>
  dplyr::summarise(
    n = dplyr::n(),
    downloaded = sum(downloaded),
    scanned    = sum(is_scanned %in% TRUE),
    ocr        = sum(ocr_applied),
    tei        = sum(tei_ok),
    tei_pct    = round(100 * sum(tei_ok) / dplyr::n(), 1),
    .groups = "drop") |>
  dplyr::arrange(dplyr::desc(n))
readr::write_csv(by_country, OUT_CSV)

cat("\n=== MODULE 05: retrieval by country ===\n"); print(by_country)
cat("\n=== failure reasons ===\n")
print(ret |> dplyr::filter(!tei_ok) |> dplyr::count(failure_reason, sort = TRUE))
cat(sprintf("\nFull text as TEI: %d / %d (%.1f%%)\n",
            sum(ret$tei_ok), NROW(ret), 100 * mean(ret$tei_ok)))
cat(sprintf("Scanned PDFs needing OCR: %d (OCR succeeded on %d)\n",
            sum(ret$is_scanned %in% TRUE), sum(ret$ocr_applied)))
.log(list(event = "run_done", n = NROW(ret), tei_ok = sum(ret$tei_ok),
          scanned = sum(ret$is_scanned %in% TRUE)))
cat(sprintf("\nWrote %s\n     %s\n", OUT_PATH, OUT_CSV))
