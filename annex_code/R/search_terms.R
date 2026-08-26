# ---------------------------------------------------------------------------
# search_terms.R — concept blocks for Module 02. Verbatim from the protocol.
# Any change here is a protocol amendment; log in rmd/01_protocol.Rmd.
# ---------------------------------------------------------------------------

CONFLICT_EN <- c(
  "human-wildlife conflict", "human wildlife conflict",
  "human-wildlife coexistence", "human-wildlife interaction",
  "crop raiding", "crop damage", "crop depredation",
  "livestock depredation", "livestock predation",
  "retaliatory killing", "problem animal", "wildlife damage",
  "depredation", "persecution", "poisoning",
  "attacks on humans", "bycatch", "by-catch", "incidental catch"
)

WILDLIFE_EN <- c(
  "wildlife", "mammal", "carnivore", "primate", "macaque", "ungulate",
  "boar", "jackal", "hyaena", "hyena", "fox", "mongoose", "porcupine",
  "raptor", "eagle", "vulture", "falcon", "stork", "flamingo",
  "reptile", "snake", "turtle", "tortoise",
  "dolphin", "cetacean", "seal", "shark",
  "Sus scrofa", "Canis aureus", "Canis lupaster", "Hyaena hyaena",
  "Macaca sylvanus", "Caretta caretta", "Monachus monachus",
  "Hystrix cristata", "Vulpes zerda", "Gazella dorcas", "Ammotragus lervia"
)

GEOGRAPHY_EN <- list(
  Tunisia = c("Tunisia", "Tunisian"),
  Algeria = c("Algeria", "Algerian"),
  Morocco = c("Morocco", "Moroccan"),
  Libya   = c("Libya",   "Libyan"),
  Egypt   = c("Egypt",   "Egyptian"),
  Region  = c("North Africa", "Northern Africa", "Maghreb",
              "Atlas Mountains", "Gulf of Gabes", "Gulf of Gabès",
              "Ichkeul", "Djurdjura", "Kroumirie")
)

# French — do NOT machine-translate. Human-selected terms per protocol.
CONFLICT_FR <- c(
  "conflit homme-faune", "conflits homme-animal",
  "dégâts de sanglier", "dégâts aux cultures",
  "prédation du bétail", "capture accidentelle", "prise accessoire"
)
WILDLIFE_FR <- c("sanglier", "chacal", "hyène rayée", "macaque de Barbarie")
GEOGRAPHY_FR <- c("Tunisie", "Algérie", "Maroc", "Libye", "Égypte",
                  "Maghreb", "Afrique du Nord")

# Arabic — transliteration decisions documented here.
#
# Choices made:
#   * Use standard MSA (Modern Standard Arabic) terms; local dialects
#     are not used because bibliographic indexing normalises to MSA.
#   * Country names use their canonical MSA forms with the definite
#     article (ال) where standard (e.g. الجزائر, المغرب).
#   * "Human-wildlife conflict" is a Western coinage. The closest MSA
#     rendering used in academic writing is
#     "الصراع بين الإنسان والحياة البرية"; some sources use
#     "التعارض" instead of "الصراع".
#   * Low yield is expected and is itself a finding about Arabic
#     scholarly indexing coverage, not an empirical zero.
CONFLICT_AR <- c(
  "الصراع بين الإنسان والحياة البرية",
  "التعارض بين الإنسان والحياة البرية",
  "تعايش الإنسان والحياة البرية",
  "أضرار المحاصيل",
  "افتراس الماشية",
  "الصيد العرضي"
)
WILDLIFE_AR <- c(
  "الحياة البرية", "خنزير بري", "ابن آوى", "ضبع", "سلحفاة بحرية"
)
GEOGRAPHY_AR <- c(
  "تونس", "الجزائر", "المغرب", "ليبيا", "مصر",
  "شمال أفريقيا", "المغرب العربي"
)

# Helper — quote each phrase (surface with spaces) for Boolean search.
q <- function(x) {
  ifelse(grepl("\\s", x), paste0('"', x, '"'), x)
}
