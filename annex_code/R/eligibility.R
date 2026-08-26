# ---------------------------------------------------------------------------
# eligibility.R — machine-readable eligibility criteria for the automated
# evidence map. Sourced by Module 04b (classification) and Module 06
# (extraction) so classifier prompts cannot drift from the published protocol.
#
# EDITS TO THIS FILE ARE PROTOCOL AMENDMENTS. Log them in the amendments
# section of rmd/01_protocol.Rmd with a dated entry and a reason.
# ---------------------------------------------------------------------------

ELIGIBILITY <- list(

  design = paste(
    "Automated evidence map of human-wildlife conflict and coexistence",
    "research across Algeria, Egypt, Libya, Morocco and Tunisia.",
    "NOT a systematic review; NOT a PRISMA-ScR scoping review.",
    "Follows PRISMA-ScR reporting conventions where they apply."
  ),

  # PCC = Population, Concept, Context (JBI evidence-map framework).
  pcc = list(
    population = paste(
      "Wild species in contested interactions with people, and the",
      "human communities affected by those interactions."
    ),
    concept = c(
      "conflict", "coexistence", "damage", "depredation",
      "persecution", "bycatch", "mitigation"
    ),
    context = list(
      countries   = c("Tunisia", "Algeria", "Morocco", "Libya", "Egypt"),
      terrestrial = TRUE,
      marine      = TRUE
    )
  ),

  include = c(
    "Empirical study, review, or policy/management analysis.",
    "Concerns at least one of the five countries in a spatially explicit way (country named, or a named region within one).",
    "Addresses a negative or contested human-wildlife interaction, or an intervention intended to prevent or mitigate one.",
    "Publication year >= 1990.",
    "Language: English, French, or Arabic."
  ),

  exclude = c(
    "Purely taxonomic, phylogenetic, physiological, or veterinary study with no human dimension.",
    "Human-only or livestock-only study with no wild-species component."
  ),

  # Borderline case rules. These are the single most consequential decisions
  # in the protocol: they define what the evidence map counts as HWC and go
  # verbatim into Module 04b classification prompts.
  #
  # Each rule states the VERDICT (INCLUDE / EXCLUDE / CONDITIONAL) and the
  # RATIONALE. Rationales matter because the classifier will reason from them
  # on cases we did not anticipate.
  borderline = list(

    invasive_species_management = list(
      verdict = "CONDITIONAL",
      rule = paste(
        "INCLUDE when the paper frames the species as causing damage,",
        "conflict, or requiring mitigation involving people or their assets.",
        "EXCLUDE pure biocontrol, eradication ecology, or invasion biology",
        "with no human-conflict framing."
      ),
      rationale = paste(
        "Wild boar in the Maghreb is native but demographically expanding and",
        "is often studied under an 'invasive' framing; the underlying damage",
        "phenomenon is exactly what this map wants to capture."
      )
    ),

    game_and_hunting_management = list(
      verdict = "CONDITIONAL",
      rule = paste(
        "INCLUDE when hunting is motivated by damage prevention or",
        "human-safety concerns. EXCLUDE pure harvest / quota / trophy",
        "management with no damage or conflict framing."
      ),
      rationale = paste(
        "Sport-hunting biology is a separate evidence base. Damage-motivated",
        "hunting is a canonical HWC response and belongs in the map."
      )
    ),

    wildlife_trade = list(
      verdict = "EXCLUDE",
      rule = paste(
        "EXCLUDE by default. INCLUDE only when trade is documented as a",
        "direct consequence of retaliatory killing arising from a",
        "human-wildlife conflict (e.g. body parts of killed depredators)."
      ),
      rationale = paste(
        "Wildlife trade has its own mature evidence base and its own maps;",
        "conflating the two would blur both."
      )
    ),

    bird_crop_damage = list(
      verdict = "INCLUDE",
      rule = paste(
        "INCLUDE all studies of avian damage to crops or stored produce",
        "in the five countries (e.g. sparrows, starlings, storks on",
        "cereals, dates, olives)."
      ),
      rationale = paste(
        "Canonical HWC subtype; regionally important given Maghreb cereal",
        "and date-palm agriculture."
      )
    ),

    human_primate_disease_transmission = list(
      verdict = "CONDITIONAL",
      rule = paste(
        "EXCLUDE pure zoonosis / epidemiology studies. INCLUDE when",
        "disease is discussed as a driver of persecution, tourism policy,",
        "or coexistence intervention (e.g. Barbary macaque and herpes-B)."
      ),
      rationale = paste(
        "Disease itself is not conflict; disease-driven persecution is."
      )
    ),

    wildlife_vehicle_collision = list(
      verdict = "INCLUDE",
      rule = paste(
        "INCLUDE all documented vertebrate-vehicle collision studies in",
        "the five countries, terrestrial or coastal."
      ),
      rationale = paste(
        "Canonical HWC subtype. Under-representation in North Africa is",
        "itself expected to be one of the map's headline findings."
      )
    )
  ),

  languages = c("en", "fr", "ar"),
  year_from = 1990L,

  grey_literature = list(
    include = TRUE,
    stratum_rule = paste(
      "Grey literature (theses, NGO reports, government documents,",
      "conference proceedings) is kept as a separate stratum and NEVER",
      "merged with peer-reviewed in headline counts. The contrast is a",
      "result in its own right."
    )
  ),

  provenance = list(
    written  = as.Date("2026-08-12"),
    frozen_before_search = TRUE,
    embedded_in_classifier_prompts = "rmd/04b_classify.Rmd"
  )
)
