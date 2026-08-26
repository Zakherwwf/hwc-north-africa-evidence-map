# ---------------------------------------------------------------------------
# species_reference.R — the a priori set of species plausibly involved in
# human-wildlife conflict in North Africa.
#
# WHY THIS LIST AND NOT ANOTHER
# Module 07 must "name species with documented conflict and zero studies".
# That requires a reference set fixed INDEPENDENTLY of what the search found,
# or the zero-cell analysis becomes circular: assembling the list after seeing
# the results guarantees every species on it has studies.
#
# This list is the eleven Latin binomials written into the protocol's wildlife
# search block in Module 01, frozen before any search ran, and chosen at that
# time as the taxa plausibly involved in regional conflict. Using them here is
# therefore pre-specified rather than post-hoc: the search actively looked for
# each one, so a species with zero studies is a species the search sought and
# failed to find.
#
# Common names are the standard English vernacular for each binomial and are
# used only to widen matching, never to add taxa to the reference set.
# ---------------------------------------------------------------------------

SPECIES_REFERENCE <- tibble::tribble(
  ~scientific,          ~common,                  ~conflict_context,
  "Sus scrofa",         "wild boar",              "crop damage",
  "Canis aureus",       "golden jackal",          "livestock depredation",
  "Canis lupaster",     "African wolf",           "livestock depredation",
  "Hyaena hyaena",      "striped hyaena",         "livestock depredation, persecution",
  "Macaca sylvanus",    "Barbary macaque",        "crop damage, tourism conflict",
  "Caretta caretta",    "loggerhead turtle",      "fisheries bycatch",
  "Monachus monachus",  "Mediterranean monk seal","fisheries interaction",
  "Hystrix cristata",   "crested porcupine",      "crop damage",
  "Vulpes zerda",       "fennec fox",             "persecution, trade",
  "Gazella dorcas",     "dorcas gazelle",         "hunting, competition",
  "Ammotragus lervia",  "aoudad",                 "hunting, competition")

# Extra vernacular forms that refer to the same taxon. Matching only, never
# new taxa. Kept explicit so the match rule is auditable.
SPECIES_ALIASES <- list(
  "Sus scrofa"        = c("wild boar", "boar", "sanglier"),
  "Canis aureus"      = c("golden jackal", "jackal", "chacal"),
  "Canis lupaster"    = c("african wolf", "african golden wolf", "canis anthus"),
  "Hyaena hyaena"     = c("striped hyaena", "striped hyena", "hyaena", "hyena"),
  "Macaca sylvanus"   = c("barbary macaque", "barbary ape", "macaque"),
  "Caretta caretta"   = c("loggerhead"),
  "Monachus monachus" = c("monk seal"),
  "Hystrix cristata"  = c("crested porcupine", "porcupine"),
  "Vulpes zerda"      = c("fennec"),
  "Gazella dorcas"    = c("dorcas gazelle"),
  "Ammotragus lervia" = c("aoudad", "barbary sheep"))

species_pattern <- function(sci) {
  terms <- unique(tolower(c(sci,
    SPECIES_REFERENCE$common[SPECIES_REFERENCE$scientific == sci],
    SPECIES_ALIASES[[sci]])))
  paste0("\\b(", paste(gsub("([.*+?^${}()|\\[\\]\\\\])", "\\\\\\1", terms),
                       collapse = "|"), ")")
}
