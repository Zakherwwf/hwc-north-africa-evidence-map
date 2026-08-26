# ---------------------------------------------------------------------------
# run_fetch_context.R — country denominators for Module 07.
#
# Module 07 reports studies per country normalised by land area and by
# population, because a raw count conflates "little research happens here"
# with "this is a small country". Those denominators are external reference
# data and are FETCHED, not typed: a recalled population figure presented as a
# World Bank number is a fabricated number under rule 1, however close it
# happens to land.
#
# Source: World Bank Open Data API (no key, no rate limit of consequence).
#   AG.LND.TOTL.K2  land area, sq. km
#   SP.POP.TOTL     total population
# `mrnev=1` returns each country's most recent non-empty value; the year of
# each observation is carried through so the write-up can state it.
#
# ONE CAVEAT THAT MATTERS FOR THE MAP
# The World Bank's land area for Morocco excludes Western Sahara (~266,000
# sq. km). Study locations in our corpus are assigned by a model reading the
# paper, which will not apply that boundary consistently. Morocco's
# studies-per-area figure is therefore an upper bound, and Module 07 says so
# rather than quietly picking one convention.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr)
  library(jsonlite); library(httr)
})
source(here::here("R", "config.R"))

WB_BASE   <- "https://api.worldbank.org/v2"
ISO3      <- c(Tunisia = "TUN", Algeria = "DZA", Morocco = "MAR",
               Libya = "LBY", Egypt = "EGY")
INDICATORS <- c(land_area_km2 = "AG.LND.TOTL.K2", population = "SP.POP.TOTL")

OUT_PATH  <- here::here(DIR_EXTERNAL, "country_context.rds")
OUT_CSV   <- here::here(DIR_EXTERNAL, "country_context.csv")
CACHE_DIR <- here::here("cache", "worldbank")
LOG_PATH  <- here::here(DIR_LOGS, sprintf("07_context_%s.jsonl", format(Sys.Date(), "%Y%m%d")))

.log <- function(x) cat(jsonlite::toJSON(c(x, list(when = format(Sys.time()))),
                        auto_unbox = TRUE, null = "null"), "\n",
                        file = LOG_PATH, append = TRUE)

dir.create(CACHE_DIR, showWarnings = FALSE, recursive = TRUE)
dir.create(here::here(DIR_EXTERNAL), showWarnings = FALSE, recursive = TRUE)

.fetch_indicator <- function(code) {
  cp <- file.path(CACHE_DIR, sprintf("%s.json", code))
  if (file.exists(cp)) {
    txt <- paste(readLines(cp, warn = FALSE), collapse = "")
  } else {
    url <- sprintf("%s/country/%s/indicator/%s?format=json&per_page=100&mrnev=1",
                   WB_BASE, paste(ISO3, collapse = ";"), code)
    r <- httr::GET(url, httr::user_agent("hwc-na-evidence-map/0.1"), httr::timeout(60))
    if (httr::status_code(r) != 200)
      stop(sprintf("World Bank returned HTTP %d for %s", httr::status_code(r), code))
    txt <- httr::content(r, "text", encoding = "UTF-8")
    writeLines(txt, cp)
    .log(list(event = "fetched", indicator = code, bytes = nchar(txt)))
  }
  p <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
  if (length(p) < 2 || !length(p[[2]]))
    stop(sprintf("World Bank returned no observations for %s", code))
  purrr_rows <- lapply(p[[2]], function(o) tibble::tibble(
    iso3  = o$countryiso3code,
    wb_name = o$country$value,
    year  = as.integer(o$date),
    value = if (is.null(o$value)) NA_real_ else as.numeric(o$value)))
  dplyr::bind_rows(purrr_rows)
}

ctx <- NULL
for (nm in names(INDICATORS)) {
  d <- .fetch_indicator(INDICATORS[[nm]]) |>
    dplyr::rename(!!nm := value, !!paste0(nm, "_year") := year)
  ctx <- if (is.null(ctx)) d else
    dplyr::full_join(ctx, d |> dplyr::select(-wb_name), by = "iso3")
}

ctx <- tibble::tibble(country = names(ISO3), iso3 = unname(ISO3)) |>
  dplyr::left_join(ctx, by = "iso3") |>
  dplyr::mutate(pop_density = population / land_area_km2)

# Every country must have both denominators, or the normalisation below is
# silently uneven across the map.
stopifnot(NROW(ctx) == length(ISO3),
          !any(is.na(ctx$land_area_km2)), !any(is.na(ctx$population)))

saveRDS(ctx, OUT_PATH)
readr::write_csv(ctx, OUT_CSV)

cat("\n=== COUNTRY CONTEXT (World Bank Open Data) ===\n")
print(as.data.frame(ctx |> dplyr::mutate(
  land_area_km2 = format(land_area_km2, big.mark = ",", trim = TRUE),
  population    = format(population, big.mark = ",", trim = TRUE),
  pop_density   = round(pop_density, 1))))

cat(sprintf("\nLand area observations: %s\n",
            paste(sort(unique(ctx$land_area_km2_year)), collapse = ", ")))
cat(sprintf("Population observations: %s\n",
            paste(sort(unique(ctx$population_year)), collapse = ", ")))
cat("\nNote: World Bank land area for Morocco excludes Western Sahara.\n")

.log(list(event = "run_done", n = NROW(ctx),
          land_years = unique(ctx$land_area_km2_year),
          pop_years = unique(ctx$population_year)))
cat(sprintf("\nWrote %s\n      %s\n", OUT_PATH, OUT_CSV))
sessionInfo()
