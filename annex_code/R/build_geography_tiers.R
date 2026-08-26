# ---------------------------------------------------------------------------
# build_geography_tiers.R — Module 06 stage 0b: confidence tiers over the
# geographic verification verdicts.
#
# WHY TIERS
# run_verify_geography.R asks one model one question per record and returns a
# boolean. That boolean is the analytic gate for the whole evidence map, so it
# should not be consumed unqualified. This script grades each in-scope verdict
# by whether the record's own title+abstract independently corroborates it:
#
#   A_named_country_corroborated  model named one of the five countries
#   B_regional_corroborated       model said in-scope, and a North Africa place
#                                 string is present in title+abstract
#   C_asserted_no_evidence        model said in-scope, but NO place string is
#                                 present anywhere in title+abstract
#   E_out_of_scope                model said out of scope
#
# Tier C is the stratum at risk. Module 07 reports every headline count with
# and without it; that is robustness variant (f) alongside the five the
# protocol names.
#
# NON-STUDY RECORDS
# An earlier ad-hoc version of this file carried a sixth tier, D_nonstudy,
# holding 9 records marked by eye as bibliographies, editorials and off-topic
# articles. That is a human screening decision, and this pipeline's central
# claim is that no human screened records. It is removed. Its defensible part
# — that paratext and editorials are not studies — is recovered here from
# OpenAlex `type`, which is metadata, not judgement. The remaining 6 records
# stay in the analytic set and are handled by extraction like any other.
#
# The place-term list is the protocol's GEOGRAPHY_EN block plus "nile" and
# "tunis", both of which name in-scope locations that the country adjectives
# miss (Lake Nasser, Tunis). This reproduces the ad-hoc tiering on 549 of 550
# records; the one mover goes B -> C, i.e. to the more cautious tier.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr); library(jsonlite)
})
source(here::here("R", "config.R"))
source(here::here("R", "search_terms.R"))

STAMP    <- format(Sys.Date(), "%Y%m%d")
LOG_PATH <- here::here(DIR_LOGS, sprintf("06_tiers_%s.jsonl", STAMP))
OUT_PATH <- here::here(DIR_DERIVED, "geography_tiers.rds")
OUT_CSV  <- here::here(DIR_DERIVED, "geography_tiers.csv")

# Record types that are not studies. Metadata-derived, no record is read.
NONSTUDY_TYPES <- c("paratext", "editorial", "supplementary-materials")

PLACE_TERMS <- c(tolower(unlist(GEOGRAPHY_EN, use.names = FALSE)),
                 "morocc", "algeri", "tunisi", "libya", "egypt",
                 "gulf of gab", "nile", "tunis")
PLACE_PAT   <- paste(unique(PLACE_TERMS), collapse = "|")

.log <- function(x) cat(jsonlite::toJSON(c(x, list(when = format(Sys.time()))),
                        auto_unbox = TRUE, null = "null"), "\n",
                        file = LOG_PATH, append = TRUE)

geo  <- readRDS(here::here(DIR_DERIVED, "geography_verification.rds"))
ledg <- readRDS(here::here(DIR_DERIVED, "dedup_ledger.rds")) |>
  dplyr::distinct(id, .keep_all = TRUE) |>
  dplyr::select(id, abstract, type, publication_year, language, source_container)

stopifnot(NROW(geo) == 550L, all(geo$verified))

tiers <- geo |>
  dplyr::left_join(ledg, by = "id") |>
  dplyr::mutate(
    ta        = tolower(paste(title, abstract)),
    ta_place  = grepl(PLACE_PAT, ta),
    q_place   = grepl(PLACE_PAT, tolower(dplyr::coalesce(quote, ""))),
    q_ok      = quote_grounded %in% TRUE,
    named_one = study_country %in% COUNTRIES,
    nonstudy  = type %in% NONSTUDY_TYPES,
    tier = dplyr::case_when(
      !(in_scope %in% TRUE) ~ "E_out_of_scope",
      named_one             ~ "A_named_country_corroborated",
      ta_place              ~ "B_regional_corroborated",
      TRUE                  ~ "C_asserted_no_evidence"),
    # The analytic set for Modules 06-07: model says in-scope AND the record
    # is a study by type. Tier C stays in, flagged, and is stripped in the
    # robustness pass.
    analytic = (in_scope %in% TRUE) & !nonstudy)

stopifnot(!any(is.na(tiers$tier)), NROW(tiers) == NROW(geo))

saveRDS(tiers, OUT_PATH)
readr::write_csv(tiers |> dplyr::select(-ta, -abstract, -quote), OUT_CSV)

cat("\n=== GEOGRAPHY CONFIDENCE TIERS ===\n")
print(tiers |> dplyr::count(tier))
cat("\n=== non-study by OpenAlex type (excluded from analytic set) ===\n")
print(tiers |> dplyr::filter(nonstudy) |> dplyr::count(tier, type))
cat(sprintf("\nAnalytic set: %d of %d verified records (%d in-scope, minus %d non-study)\n",
            sum(tiers$analytic), NROW(tiers), sum(tiers$in_scope %in% TRUE),
            sum(tiers$analytic != (tiers$in_scope %in% TRUE))))
cat("\n=== analytic set by verified country ===\n")
print(tiers |> dplyr::filter(analytic) |> dplyr::count(study_country, sort = TRUE))
cat("\n=== quote corroboration within the analytic set ===\n")
print(tiers |> dplyr::filter(analytic) |>
      dplyr::count(tier, quote_grounded = q_ok, quote_names_place = q_place))

.log(list(event = "tiers_built", n = NROW(tiers), analytic = sum(tiers$analytic),
          A = sum(tiers$tier == "A_named_country_corroborated"),
          B = sum(tiers$tier == "B_regional_corroborated"),
          C = sum(tiers$tier == "C_asserted_no_evidence"),
          E = sum(tiers$tier == "E_out_of_scope"),
          nonstudy = sum(tiers$nonstudy)))
cat(sprintf("\nWrote %s\n      %s\n", OUT_PATH, OUT_CSV))
sessionInfo()
