# North Africa HWC Evidence Map — Fully Automated Pipeline

Paste as the opening message in Claude Code, in an empty project directory. Runs end to end with no human in the loop.

---

## WHAT WE'RE BUILDING AND WHY THE DESIGN CHANGED

An **automated evidence map** of human–wildlife conflict and coexistence research across Algeria, Egypt, Libya, Morocco and Tunisia, producing a conference abstract (250 and 300 words) and an A0 portrait poster plan for the 2nd International Conference on Human-Wildlife Conflict and Coexistence, Bangkok, March 2027.

**Read this before anything else.** The original plan was a PRISMA-ScR scoping review. A scoping review makes claims about a precisely-bounded *included set*, so every screening decision matters and a human reviewer is structurally required. Since this pipeline must run without a human, the design changes to an **evidence map**: claims about the *distribution* of research across countries, species, conflict types and methods.

This is not a downgrade. It is the design whose error tolerance matches an automated pipeline. If 5% of records are misclassified but errors are not systematically biased by country or taxon, the headline finding — that research is concentrated in Morocco and near-absent in Libya, that mitigation evaluation is rare, that certain conflict species have zero studies — survives intact. Distributional claims are robust to symmetric classification noise in a way boundary claims are not.

**Label it accurately throughout.** Call it an "automated evidence map" or "machine-assisted systematic evidence map," never a "systematic review" and never a "PRISMA-ScR scoping review." Follow PRISMA-ScR reporting conventions where they apply and say so, but do not claim the design.

**The contribution is the gap.** Where the evidence isn't — which countries, species, conflict types and methods are absent or thin. A summary of known literature is a failure condition. Module 07 is the point; everything else serves it.

---

## RULES THAT DON'T BEND

1. **Never fabricate a number, citation, DOI or field value.** If it can't be determined, write `NA` and log why.
2. **Never edit an assertion to make it pass.** When one fails, either the expectation or the data is wrong — investigate and report. Silently loosening a `stopifnot()` is the worst thing you can do here.
3. **Report every row loss.** Every filter, join, dedup and exclusion prints how many records it removed and why.
4. **Separate measured from inferred** in every summary.
5. **Every performance claim about the automated components must be a measured number**, produced by Module 04a. No unvalidated automation anywhere.

---

## STACK — all local, no paid APIs

| Job | Tool |
|---|---|
| Search | OpenAlex (`openalexR`, no key), CORE (free key), Crossref; BASE/OpenAIRE for grey literature |
| Classification | Local model ensemble via `mlx_lm.server`, schema-constrained JSON |
| Validation | SYNERGY and SESR-Eval open benchmarks |
| PDF → structure | GROBID (Docker) → TEI XML; Docling as ARM fallback |
| Scanned docs | `ocrmac` (Apple Vision) or `tesseract` with `fra`/`ara` |
| Analysis, figures | R |

Apple Silicon. Unlimited-OCR is CUDA-only and unusable. Scopus and Web of Science excluded — document in the protocol.

**Ensemble:** serve two or three models with genuinely different training lineages — e.g. Gemma 4 12B and Qwen3.6 14B (add a third if memory allows). Different families make correlated errors less likely, which is the entire point of an ensemble. At 16GB unified, serve them sequentially rather than concurrently.

R for all analysis and outputs; Python only for GROBID, OCR and model serving.

---

## REPRODUCIBILITY CONTRACT

- All analysis in `.Rmd`, each knitting standalone from serialised files in `data/derived/`
- `here::here()` everywhere; no `setwd()`, no absolute paths
- `knitr::opts_chunk$set(echo = TRUE, warning = TRUE, message = TRUE, dpi = 300)` — **never** global `warning = FALSE` or `message = FALSE`
- Name every chunk
- **Every number in prose via inline R**, never a typed constant
- **All API and model outputs cached to dated files; knits read cache, never re-run inference**
- Assertions at every stage boundary; record arithmetic must reconcile
- Every table to `tables/` as CSV; every figure to `figures/` as PNG and SVG at 300 dpi
- `sessionInfo()` closing every module; maintain `renv.lock`
- **Log the exact prompt text, model name, quantisation, temperature and seed for every inference run.** These are method parameters, not implementation details — they belong in the supplementary material.
- `.gitignore` covering `.Renviron`, cached PDFs, model weights — in the first commit

---

## PARAMETERS

`R/config.R`:

```r
SCOPE_MARINE     <- TRUE
LANGUAGES        <- c("en", "fr", "ar")
COUNTRIES        <- c("Tunisia", "Algeria", "Morocco", "Libya", "Egypt")
YEAR_FROM        <- 1990
INCLUDE_GREY     <- TRUE
ENSEMBLE_MODELS  <- c("gemma-4-12b-it-4bit", "qwen3.6-14b-instruct-4bit")
DECISION_RULE    <- "union"   # include if ANY model includes — maximises recall
N_RUNS_PER_ITEM  <- 2         # self-consistency at temperature 0
TARGET_RECALL    <- 0.95      # benchmark-calibrated threshold
```

---

## RUN ORDER

**`00_setup.Rmd`** — Scaffold `data/{raw,derived,external,benchmarks}`, `R`, `rmd`, `figures`, `tables`, `output`. Initialise `renv`, `.gitignore`, first commit. Verify: GROBID processes three real PDFs on ARM (switch to Docling if it fights the architecture); each ensemble model returns schema-valid JSON; CORE key works; OpenAlex returns sensible North Africa results — confirm the Ghandri wild boar papers and the Gulf of Gabès turtle bycatch papers appear. Report each model's memory footprint and tokens/sec.

**`01_protocol.Rmd`** — Eligibility criteria, written and committed **before** searching. PCC: Population = wild species in contested interactions with people, plus affected communities; Concept = conflict, coexistence, damage, depredation, persecution, bycatch, or mitigation; Context = the five countries, terrestrial and marine.

Include: empirical data, review, or policy/management analysis; concerns ≥1 of the five countries; addresses a negative or contested human–wildlife interaction or an intervention against one; 1990 onward; English, French or Arabic.

Exclude: purely taxonomic/phylogenetic/physiological/veterinary with no human dimension; human- or livestock-only.

**Write the rule for each borderline case now, not during classification**: invasive species management; game/hunting management without a damage framing; wildlife trade; bird crop damage; human–primate disease transmission; wildlife–vehicle collisions. These rules go verbatim into the classification prompt, so ambiguity here becomes noise downstream.

**`02_search.Rmd`** — Three concept blocks joined with AND, built per source.

*Conflict:* "human-wildlife conflict" OR "human wildlife conflict" OR "human-wildlife coexistence" OR "human-wildlife interaction" OR "crop raiding" OR "crop damage" OR "crop depredation" OR "livestock depredation" OR "livestock predation" OR "retaliatory killing" OR "problem animal" OR "wildlife damage" OR depredation OR persecution OR poisoning OR "attacks on humans" OR bycatch OR "by-catch" OR "incidental catch"

*Wildlife:* wildlife OR mammal\* OR carnivor\* OR primate OR macaque OR ungulate OR boar OR jackal OR hyaena OR hyena OR fox OR mongoose OR porcupine OR raptor OR eagle OR vulture OR falcon OR stork OR flamingo OR reptile OR snake OR turtle OR tortoise OR dolphin OR cetacean OR seal OR shark OR "Sus scrofa" OR "Canis aureus" OR "Canis lupaster" OR "Hyaena hyaena" OR "Macaca sylvanus" OR "Caretta caretta" OR "Monachus monachus" OR "Hystrix cristata" OR "Vulpes zerda" OR "Gazella dorcas" OR "Ammotragus lervia"

*Geography:* Tunisia\* OR Algeria\* OR Morocc\* OR Egypt\* OR Libya\* OR "North Africa\*" OR "Northern Africa" OR Maghreb OR "Atlas Mountains" OR "Gulf of Gabes" OR "Gulf of Gabès" OR Ichkeul OR Djurdjura OR Kroumirie

*French, separate search — do not machine-translate:* "conflit homme-faune" OR "conflits homme-animal" OR "dégâts de sanglier" OR "dégâts aux cultures" OR "prédation du bétail" OR sanglier OR chacal OR "hyène rayée" OR "macaque de Barbarie" OR "capture accidentelle" OR "prise accessoire" AND (Tunisie OR Algérie OR Maroc OR Libye OR Égypte OR Maghreb OR "Afrique du Nord")

*Arabic:* construct and document transliteration decisions. Low yield is an indexing finding, not evidence of absent research.

Plus backward and forward citation from the 20 highest-relevance records. Keep grey literature as a separate stratum — **never merge grey and peer-reviewed in headline counts**; the contrast is a result.

Cast wide. Under an automated design, over-retrieval costs machine time, not human time.

**`03_deduplicate.Rmd`** — Normalised DOI exact match, then Jaro-Winkler on normalised titles (~0.95) with year within ±1. Log every merge. Report duplicates by method and source overlap.

**`04a_validate_classifier.Rmd` — RUN THIS BEFORE CLASSIFYING ANYTHING.**

This module is what makes the whole pipeline defensible. It produces the performance numbers you will report.

1. Download **SYNERGY** (the ASReview benchmark, openly available with labels) and **SESR-Eval**. Select 3–5 datasets, favouring low-prevalence ones — our prevalence will also be low, and low-prevalence screening is where classifiers fail.
2. Run the **exact** ensemble, prompt template and decision rule you will use on the real corpus. Do not tune on the real corpus.
3. Report per model and for the ensemble: **sensitivity (recall), specificity, precision, F1, Cohen's κ, MCC, and Gwet's AC1.** In low-prevalence settings κ collapses even when performance is good — report the alternatives alongside it and explain why.
4. **Prompt-polarity robustness.** Screening performance is known to be sensitive to how criteria are phrased. Test at least three logically-equivalent phrasings — affirmative inclusion, antonymic exclusion, predicate negation — and report the spread. Use the best-performing phrasing on the real corpus and disclose that you selected it on benchmark data, not on your own.
5. **Calibrate to `TARGET_RECALL`.** Adjust the decision threshold or rule until benchmark recall ≥0.95. Report the resulting specificity honestly — it will be poor, and that is the intended trade.
6. If ensemble recall cannot reach 0.95 on benchmarks, **stop and report that**. Do not proceed with an uncalibrated classifier.

Cite: van de Schoot et al. 2021 (*Nature Machine Intelligence*) for SYNERGY; Sanghera et al. 2025 (*JAMIA*) for ensemble screening; the LLM4SCREENLIT reporting recommendations.

**`04b_classify.Rmd`** — Classify **every deduplicated record**. No sampling, no active learning, no stopping rule — a machine reads all of them, so early-termination recall risk does not exist.

Each record, each model, `N_RUNS_PER_ITEM` runs at temperature 0. Output schema: `include` (boolean), `confidence` (low/medium/high), `primary_reason`, `supporting_phrase` (verbatim from title or abstract).

Apply the **union rule**: include if any model in any run includes. Then record three quantities that become results in their own right:
- **Inter-model agreement** (κ and raw agreement between models)
- **Self-consistency** (agreement between runs of the same model)
- **Contested set** — records where models disagree. Report its size and composition; a small contested set is evidence of a well-specified criterion, a large one is a warning about the criteria themselves.

**`05_fulltext.Rmd`** — Retrieve PDFs (CORE/Unpaywall first). GROBID → TEI. Count extractable characters per page; near-zero means a scan — OCR those with `ocrmac`. Report retrieval success rate by country and language; **retrieval failure is itself a finding about access inequality**, so break it down rather than reporting one number.

**`06_extract.Rmd`** — Schema-constrained extraction from the methods and results sections of the TEI, not whole papers.

Fields: `study_id, authors, year, language, source_type, journal, country, subnational_region, marine_terrestrial, species_common, species_scientific, taxonomic_class, conflict_type, study_design, sample_size, years_of_data, damage_metric_reported, damage_estimate, mitigation_tested, mitigation_type, mitigation_outcome_measured, outcome_direction, stakeholder_engagement, compensation_scheme_discussed, funding_source, author_affiliation_country`.

Four automated verification mechanisms, all mandatory:

1. **Quote-grounding.** Every non-null field carries a verbatim `evidence_quote` plus its source section. **String-match every quote back against the extracted text.** Quotes not found are auto-flagged and the field set to `NA` with reason `unverified_quote`. Report the grounding failure rate per field — this is a directly measured hallucination rate and it is stronger evidence than any spot-check.
2. **Self-consistency.** Two runs at temperature 0; disagreement sets `NA` with reason `inconsistent_extraction`.
3. **Cross-model extraction** on a random 20% for inter-model agreement per field.
4. **Every enum includes `"not stated"`.** Without an escape hatch the model invents plausible values, and absence is exactly what we are measuring.

Report a per-field reliability table: grounding rate, self-consistency, cross-model agreement. **Fields below 0.70 on any measure are excluded from the headline analysis** and reported as unreliable. Say which fields those were.

**`07_evidence_map.Rmd` — the contribution.**
- **Geographic:** studies per country, normalised by land area and population. Quantify the gap.
- **Taxonomic:** studies per species and class against the set plausibly involved in regional conflict. **Name species with documented conflict and zero studies.**
- **Conflict type:** which are studied, which aren't; marine vs terrestrial; types documented in one country and absent in an ecologically similar neighbour.
- **Method:** perception work vs quantified damage measurement vs intervention evaluation. **Count studies that evaluate a mitigation with a measured outcome** — usually startlingly small, and the most policy-relevant number in the analysis.
- **Language and indexing:** share found only in French, only via one source, only by citation-chasing.
- **Temporal:** publications per year per country.
- **Authorship equity:** share with in-country first and senior authors.

**Then the robustness analysis, which is not optional.** Recompute every headline finding under: (a) union vs intersection decision rule; (b) high-confidence classifications only; (c) contested records included vs excluded; (d) with and without grey literature; (e) with and without records whose fields failed grounding. **Report which conclusions survive all five variants and which do not.** A finding that flips under a defensible change of rule is not a finding — say so explicitly rather than reporting the favourable variant.

Every count with its denominator visible. Where a cell is zero, print zero.

**`08_figures.Rmd`** — Flow diagram from the record ledger (PRISMA-style, labelled as an evidence-map flow, not a PRISMA-ScR diagram). All figures colour-blind-safe, PNG and SVG at 300 dpi. Include one figure showing classifier performance from Module 04a — putting your validation on the poster is a strength at a conference increasingly wary of AI-generated evidence.

**`09_outputs.Rmd`** — Abstract at 250 and 300 words: first sentence about the coexistence problem, not about databases or methods; conference topic vocabulary verbatim; two or three concrete numbers; one transferable lesson; policy implication to close.

Poster plan: one core message, three-column layout, five figures with lay captions, a "what this means if you work here" box, under 400 words body text, QR code to the deposited data.

Draft the methods paragraph on the automated components. It must state: the models, quantisation, prompts and decision rule; benchmark-derived sensitivity and specificity with the datasets named; the quote-grounding verification rate; and this sentence —

> All classification and extraction were performed by automated systems; no human reviewer screened records or extracted data. Classifier performance was validated against external labelled benchmarks prior to application, and all extracted fields were verified by verbatim quote-matching against source text. Performance metrics are reported in full; fields falling below reliability thresholds were excluded from analysis.

That paragraph is the difference between a defensible automated study and an indefensible one. Do not soften it, and do not omit it.

---

## WHEN IT'S DONE

1. What is the single most defensible number in this analysis?
2. What were the benchmark-validated sensitivity and specificity, and what do they imply about how many relevant studies we likely missed? Give an estimated count, not just a rate.
3. Which apparent gaps are real research gaps, and which are artefacts of indexing, language coverage, our search string, or classifier error? Conflating those is this study's central failure mode — be specific about which is which.
4. Which findings survived all five robustness variants and which did not?
5. Write the three sentences a hostile reviewer would use against a fully automated evidence synthesis, and the honest answer to each. One of them will be "you had no human oversight" — that answer must rest on the measured validation, not on assurance.
6. What are the weakest points in the pipeline you just built?
