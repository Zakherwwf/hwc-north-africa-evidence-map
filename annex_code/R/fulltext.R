# ---------------------------------------------------------------------------
# fulltext.R — Module 05 functions: PDF retrieval, scan detection, OCR, GROBID.
#
# Pipeline per record:
#   resolve URL -> download -> validate it is really a PDF -> inspect text layer
#   -> OCR if scanned -> GROBID -> TEI XML
#
# Every stage is cached on disk and every failure is recorded with a REASON,
# because per the protocol retrieval failure is a finding about access
# inequality, not merely an error to swallow. A record that fails is never
# silently dropped: it carries a failure_reason into the retrieval ledger.
#
# Politeness: these are third-party repository and publisher servers, not an
# API we own. Requests carry a real User-Agent with a contact address and are
# spaced by RETRIEVAL_DELAY seconds.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(httr); library(jsonlite); library(dplyr); library(pdftools); library(xml2)
})

.FULLTEXT_UA <- "hwc-na-evidence-map/0.1 (mailto:bouragaoui@wisc.edu)"
RETRIEVAL_DELAY   <- 1.0    # seconds between external requests
SCANNED_CHAR_MIN  <- 100L   # median extractable chars/page below this => scan
DOWNLOAD_TIMEOUT  <- 120L
GROBID_TIMEOUT    <- 300L

DIR_PDF <- file.path(DIR_RAW, "pdf")
DIR_TEI <- file.path(DIR_DERIVED, "tei")
DIR_OCR <- file.path(DIR_DERIVED, "ocr")

.safe_id <- function(id) {
  x <- sub("^https?://", "", id)
  gsub("[^A-Za-z0-9._-]", "_", x)
}

# ---- 1. Resolve a candidate PDF URL --------------------------------------
# Priority: the pdf_url already captured at search time, then OpenAlex's
# best_oa_location (re-fetched only when needed), then CORE by DOI.

# Hosts that front their PDFs with bot protection and answer automated
# requests with HTTP 403 regardless of the article's OA status. We do NOT
# spoof a browser to get past them -- that would be circumventing an access
# control the publisher deliberately set. Instead we look for an open
# repository copy, and if none exists the record is recorded as
# `publisher_blocked`, which is precisely the access-inequality finding the
# protocol asks Module 05 to surface.
.BLOCKED_HOSTS <- c("onlinelibrary.wiley.com", "www.sciencedirect.com",
                    "link.springer.com", "www.tandfonline.com",
                    "academic.oup.com", "www.nature.com",
                    "journals.sagepub.com", "pubs.acs.org")

.host_of <- function(u) sub("/.*$", "", sub("^https?://", "", u))
.is_blocked <- function(u) !is.na(u) && .host_of(u) %in% .BLOCKED_HOSTS

# Return ALL candidate PDF URLs for a work, ordered best-first: open
# repositories before publisher sites, and known-blocking publishers last.
.oa_pdf_candidates <- function(openalex_id) {
  key <- Sys.getenv("OPENALEX_API_KEY", unset = NA_character_)
  wid <- sub("^.*/", "", openalex_id)
  url <- sprintf("%s/works/%s", OPENALEX_BASE, wid)
  r <- tryCatch(
    if (!is.na(key))
      httr::GET(url, httr::add_headers(Authorization = paste("Bearer", key)),
                httr::user_agent(.FULLTEXT_UA), httr::timeout(30))
    else
      httr::GET(url, httr::user_agent(.FULLTEXT_UA), httr::timeout(30)),
    error = function(e) NULL)
  if (is.null(r) || httr::status_code(r) != 200) return(character(0))
  x <- tryCatch(httr::content(r, "parsed", "application/json"), error = function(e) NULL)
  if (is.null(x)) return(character(0))

  locs <- x$locations
  if (is.null(locs) || !length(locs)) locs <- list()
  grab <- function(pred) {
    u <- vapply(locs, function(l) {
      if (is.null(l$pdf_url) || !nzchar(l$pdf_url)) return(NA_character_)
      if (!pred(l)) return(NA_character_)
      as.character(l$pdf_url)
    }, character(1))
    u[!is.na(u)]
  }
  repo <- grab(function(l) identical(l$host_type, "repository"))
  pub  <- grab(function(l) !identical(l$host_type, "repository"))
  best <- c(x$best_oa_location$pdf_url, x$primary_location$pdf_url)
  best <- as.character(unlist(best[!vapply(best, is.null, logical(1))]))

  cand <- unique(c(repo, best, pub))
  cand <- cand[nzchar(cand)]
  if (!length(cand)) return(character(0))
  c(cand[!vapply(cand, .is_blocked, logical(1))],   # open hosts first
    cand[ vapply(cand, .is_blocked, logical(1))])   # blocked hosts last
}

.core_pdf_url <- function(doi) {
  key <- Sys.getenv("CORE_API_KEY", unset = NA_character_)
  if (is.na(key) || is.na(doi) || !nzchar(doi)) return(NA_character_)
  r <- tryCatch(
    httr::GET(sprintf("%s/search/works", CORE_BASE),
              query = list(q = sprintf('doi:"%s"', doi), limit = 1),
              httr::add_headers(Authorization = paste("Bearer", key)),
              httr::user_agent(.FULLTEXT_UA), httr::timeout(60)),
    error = function(e) NULL)
  if (is.null(r) || httr::status_code(r) != 200) return(NA_character_)
  x <- tryCatch(httr::content(r, "parsed", "application/json"), error = function(e) NULL)
  res <- x$results
  if (is.null(res) || !length(res)) return(NA_character_)
  u <- res[[1]]$downloadUrl
  if (is.null(u) || !nzchar(u)) NA_character_ else as.character(u)
}

# Returns an ORDERED candidate list rather than a single URL, so the caller
# can fall through to the next source when a host refuses the request.
resolve_pdf_urls <- function(rec, allow_remote_lookup = TRUE) {
  cands <- character(0); srcs <- character(0)
  if (!is.na(rec$pdf_url) && nzchar(rec$pdf_url)) {
    cands <- rec$pdf_url; srcs <- "search_ledger"
  }
  if (allow_remote_lookup && grepl("openalex", rec$id)) {
    extra <- .oa_pdf_candidates(rec$id); Sys.sleep(RETRIEVAL_DELAY)
    new <- setdiff(extra, cands)
    cands <- c(cands, new); srcs <- c(srcs, rep("openalex_lookup", length(new)))
  }
  if (allow_remote_lookup) {
    u <- .core_pdf_url(rec$doi); Sys.sleep(RETRIEVAL_DELAY)
    if (!is.na(u) && !u %in% cands) { cands <- c(cands, u); srcs <- c(srcs, "core_lookup") }
  }
  if (!length(cands)) return(list(urls = character(0), sources = character(0)))
  # Re-apply the open-host-first ordering across the merged candidate set.
  ob <- vapply(cands, .is_blocked, logical(1))
  list(urls = c(cands[!ob], cands[ob]), sources = c(srcs[!ob], srcs[ob]))
}

# ---- 2. Download and verify ----------------------------------------------
# A 200 response is NOT proof of a PDF: publishers routinely return an HTML
# paywall or cookie-consent page with status 200. Verify the %PDF magic bytes.

# Per-host pacing. Hitting one host in a tight loop earns HTTP 429 and is
# simply rude; the smoke test drew two 429s from bioRxiv this way. We keep a
# last-request clock per host and never issue two requests to the same host
# inside HOST_MIN_INTERVAL seconds.
HOST_MIN_INTERVAL <- 3.0
.host_clock <- new.env(parent = emptyenv())

.pace_host <- function(url) {
  h <- .host_of(url)
  last <- get0(h, envir = .host_clock, ifnotfound = NULL)
  if (!is.null(last)) {
    wait <- HOST_MIN_INTERVAL - as.numeric(Sys.time() - last, units = "secs")
    if (wait > 0) Sys.sleep(wait)
  }
  assign(h, Sys.time(), envir = .host_clock)
}

# Many repositories serve a landing page where a PDF was expected. The
# <meta name="citation_pdf_url"> tag is the long-standing Google Scholar
# convention for pointing at the actual file, and most repository platforms
# (DSpace, EPrints, OJS, DergiPark) emit it. Falling back to it converts a
# large share of "landing_page_not_pdf" into real retrievals.
.pdf_from_landing <- function(html, base_url) {
  m <- regmatches(html, regexpr('citation_pdf_url"[^>]*content="[^"]+"', html))
  if (length(m)) {
    u <- sub('.*content="([^"]+)".*', "\\1", m)
    if (nzchar(u)) return(xml2::url_absolute(u, base_url))
  }
  m <- regmatches(html, regexpr('content="[^"]+"[^>]*name="citation_pdf_url"', html))
  if (length(m)) {
    u <- sub('.*content="([^"]+)".*', "\\1", m)
    if (nzchar(u)) return(xml2::url_absolute(u, base_url))
  }
  NA_character_
}

download_pdf <- function(url, dest, follow_landing = TRUE, tries_429 = 3L) {
  if (file.exists(dest) && file.size(dest) > 1024)
    return(list(ok = TRUE, status = NA_integer_, reason = "cached", bytes = file.size(dest)))

  for (attempt in seq_len(tries_429)) {
    .pace_host(url)
    r <- tryCatch(
      httr::GET(url, httr::user_agent(.FULLTEXT_UA), httr::timeout(DOWNLOAD_TIMEOUT),
                httr::config(followlocation = TRUE), httr::write_disk(dest, overwrite = TRUE)),
      error = function(e) NULL)
    if (is.null(r)) { unlink(dest); return(list(ok = FALSE, status = NA_integer_,
                                                reason = "network_error", bytes = 0)) }
    st <- httr::status_code(r)
    if (st == 429 && attempt < tries_429) {
      # Retry-After may be absent, a delta-seconds value, an HTTP-date, or a
      # repeated header. Any of those can make as.numeric() return NA or a
      # vector of length != 1, so reduce to a scalar BEFORE testing it --
      # `if (NA)` and `if (logical(0))` are both hard errors in R.
      ra <- suppressWarnings(as.numeric(httr::headers(r)$`retry-after`))[1]
      wait <- if (length(ra) == 1L && !is.na(ra) && ra > 0) min(ra, 120) else 10 * attempt
      unlink(dest)
      Sys.sleep(wait)
      next
    }
    break
  }

  if (st != 200) { unlink(dest); return(list(ok = FALSE, status = st, reason = paste0("http_", st), bytes = 0)) }
  if (!file.exists(dest) || file.size(dest) < 1024) {
    unlink(dest); return(list(ok = FALSE, status = st, reason = "empty_response", bytes = 0)) }

  magic <- tryCatch(readBin(dest, "raw", n = 5), error = function(e) raw(0))
  if (!identical(rawToChar(magic[1:4]), "%PDF")) {
    ct   <- tolower(paste(httr::headers(r)$`content-type`, collapse = ""))
    # Read as raw and drop nul bytes: readChar() truncates at the first nul,
    # which can cut the document off before the citation_pdf_url tag.
    html <- tryCatch({
      raw_bytes <- readBin(dest, "raw", n = min(file.size(dest), 300000L))
      rawToChar(raw_bytes[raw_bytes != as.raw(0)])
    }, error = function(e) "")
    unlink(dest)
    if (follow_landing && grepl("html", ct)) {
      alt <- tryCatch(.pdf_from_landing(html, url), error = function(e) NA_character_)
      if (!is.na(alt) && nzchar(alt) && alt != url) {
        res <- download_pdf(alt, dest, follow_landing = FALSE)
        if (isTRUE(res$ok)) res$reason <- "downloaded_via_citation_meta"
        return(res)
      }
    }
    return(list(ok = FALSE, status = st,
                reason = if (grepl("html", ct)) "landing_page_not_pdf" else "not_a_pdf", bytes = 0))
  }
  list(ok = TRUE, status = st, reason = "downloaded", bytes = file.size(dest))
}

# ---- 3. Inspect the text layer -------------------------------------------
# Near-zero extractable characters per page means the PDF is a scan.

inspect_pdf <- function(path) {
  info <- tryCatch(pdftools::pdf_info(path), error = function(e) NULL)
  if (is.null(info)) return(list(ok = FALSE, reason = "unreadable_pdf",
                                 n_pages = NA_integer_, median_chars = NA_real_, is_scanned = NA))
  txt <- tryCatch(pdftools::pdf_text(path), error = function(e) NULL)
  if (is.null(txt)) return(list(ok = FALSE, reason = "text_extraction_failed",
                                n_pages = info$pages, median_chars = NA_real_, is_scanned = NA))
  chars <- nchar(trimws(txt))
  med   <- if (length(chars)) stats::median(chars) else 0
  list(ok = TRUE, reason = "ok", n_pages = info$pages,
       median_chars = med, is_scanned = med < SCANNED_CHAR_MIN)
}

# ---- 4. OCR scanned PDFs via Apple Vision (ocrmac) ------------------------
# Renders each page to PNG then runs Vision. Language preference covers the
# three languages in scope; Vision needs the hint to do well on fr/ar.

ocr_pdf <- function(path, out_txt, dpi = 200, max_pages = 40) {
  if (file.exists(out_txt) && file.size(out_txt) > 0) return(list(ok = TRUE, reason = "cached"))
  tmp <- file.path(tempdir(), paste0("ocr_", basename(path)))
  dir.create(tmp, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  pngs <- tryCatch(
    pdftools::pdf_convert(path, format = "png", dpi = dpi,
                          pages = seq_len(min(max_pages, pdftools::pdf_info(path)$pages)),
                          filenames = file.path(tmp, paste0("p", seq_len(min(max_pages, pdftools::pdf_info(path)$pages)), ".png")),
                          verbose = FALSE),
    error = function(e) NULL)
  if (is.null(pngs) || !length(pngs)) return(list(ok = FALSE, reason = "render_failed"))
  helper <- here::here("scripts", "ocr_image.py")
  out <- tryCatch(system2("python3", c(helper, shQuote(pngs)), stdout = TRUE, stderr = TRUE),
                  error = function(e) NULL)
  if (is.null(out) || !length(out)) return(list(ok = FALSE, reason = "ocr_failed"))
  writeLines(out, out_txt)
  list(ok = TRUE, reason = "ocr_applied")
}

# ---- 5. GROBID -> TEI ------------------------------------------------------

grobid_tei <- function(pdf_path, tei_path) {
  if (file.exists(tei_path) && file.size(tei_path) > 512)
    return(list(ok = TRUE, reason = "cached"))
  r <- tryCatch(
    httr::POST(paste0(GROBID_URL, "/api/processFulltextDocument"),
               body = list(input = httr::upload_file(pdf_path),
                           consolidateHeader = "1", segmentSentences = "0"),
               encode = "multipart", httr::timeout(GROBID_TIMEOUT)),
    error = function(e) NULL)
  if (is.null(r)) return(list(ok = FALSE, reason = "grobid_unreachable"))
  st <- httr::status_code(r)
  if (st != 200) return(list(ok = FALSE, reason = paste0("grobid_http_", st)))
  xml <- httr::content(r, "text", encoding = "UTF-8")
  if (is.na(xml) || !nzchar(xml)) return(list(ok = FALSE, reason = "grobid_empty"))
  writeLines(xml, tei_path, useBytes = TRUE)
  list(ok = TRUE, reason = "grobid_ok")
}

# Summarise a TEI so Module 06 knows whether the sections it needs exist.
tei_summary <- function(tei_path) {
  d <- tryCatch(xml2::read_xml(tei_path), error = function(e) NULL)
  if (is.null(d)) return(list(tei_ok = FALSE, n_body_chars = NA_integer_, has_methods = NA))
  ns   <- xml2::xml_ns_rename(xml2::xml_ns(d), d1 = "tei")
  body <- xml2::xml_find_all(d, "//tei:text/tei:body", ns)
  txt  <- paste(xml2::xml_text(body), collapse = " ")
  heads <- tolower(xml2::xml_text(xml2::xml_find_all(d, "//tei:body//tei:head", ns)))
  list(tei_ok = TRUE, n_body_chars = nchar(txt),
       has_methods = any(grepl("method|material|protocol|méthod", heads)))
}
