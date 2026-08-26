# Included studies — row-level data and verification guide

**262 studies. Every one named, with a DOI or OpenAlex link, and every extracted value paired with the verbatim sentence it came from.**

This directory exists so that any claim in the paper can be traced to the specific studies behind it. If the paper says 59 studies concern bycatch, you can open a file here and read all 59 titles.

## Files

| File | Rows | What it is |
|---|---|---|
| `included_studies_bibliography.md` | 262 | Formatted reference list of every included study, newest first, with country and conflict type |
| `included_studies_full.csv` | 262 × 50 | The complete register: bibliographic metadata, authorship with affiliation countries, geographic verification quote, full-text retrieval outcome, and all 20 extracted fields |
| `included_studies_reference_list.csv` | 262 | Citation-ready subset with formatted and raw author strings |
| `studies_by_conflict_type.csv` | 138 studies (156 rows) | One row per study × conflict type — the file to check any conflict-type claim |
| `studies_by_country.csv` | 310 rows | One row per study × attributed country; totals exceed 262 because multi-country studies count once per country |
| `studies_reporting_outcome_direction.csv` | 22 | The studies behind the mitigation-funnel endpoint |
| `studies_reporting_damage_estimates.csv` | 32 | Studies reporting a quantified damage estimate |
| `extraction_evidence_trail.csv` | 4,940 | Every extracted field value with its verbatim grounding quote, both models' independent values, and whether they agreed |
| `reconciliation_paper_vs_export.csv` | 13 | Each headline number in the paper against the same number recomputed from these exports |

## How to verify a claim

**"The paper says 59 studies concern bycatch — which ones?"**
Open `studies_by_conflict_type.csv`, filter `conflict_type == "bycatch"`. 59 rows, each with title, year, country, journal and DOI.

**"Study X is listed as bycatch — is that right?"**
Open `extraction_evidence_trail.csv`, filter to that `openalex_id` and `field == "conflict_type"`. You get the assigned value, the verbatim sentence from the paper that supports it, the second model's independent value, and whether the two agreed. If `consistent` is `FALSE`, the models disagreed and the value should be treated as unreliable.

**"Is this study really about North Africa?"**
`included_studies_full.csv`, column `geo_quote` — the verbatim sentence establishing the study location, which is what the geographic verification pass judged. `tier` records the strength of that grounding.

**"Do the paper's numbers actually come from this data?"**
`reconciliation_paper_vs_export.csv`. Every quantity recomputed from these files matches the published value exactly: the 262 analytic set, 121 full-text conversions, all four conflict-type counts, the 22 outcome-direction and 32 damage-estimate studies, and all five country counts.

## Reading the columns

- `openalex_id` — stable identifier; resolve as `https://openalex.org/<id>`
- `doi` / `url` — 230 of 262 studies carry a DOI; the remaining 32 are theses, reports and records where the source held none, identified by OpenAlex ID
- `tier` — geographic grounding strength from the verification pass
- `value_final` — the value used in the analysis; `value_main` and `value_probe` are the two independent model runs behind it
- `grounded_main` — whether the supporting quote was found verbatim in the source text; `FALSE` means the value was not quote-verifiable
- `consistent` — whether both model runs produced the same value
- `first_incountry` / `any_incountry` — whether a North African affiliation appears in the first-author or any-author position
- `tei_ok` — whether full text was successfully retrieved and converted (121 of 262); the remaining 141 were extracted from title and abstract only, which is why many fields read `not stated`

## Two honest caveats

**Author resolution failed for 13 records** and is marked as such rather than silently dropped. These are mostly theses and institutional reports with sparse OpenAlex metadata.

**One record carries `publication_year` 2028**, which is not possible. This is an error in the source metadata for a University of Pisa thesis, not in this pipeline. It is flagged in the `metadata_flag` column rather than corrected, because correcting source metadata silently is exactly the kind of undocumented intervention this annex exists to make visible.

## What is not here

Full-text PDFs are not redistributed — only openly licensed documents were retrieved, and redistribution is a separate permission. Use the DOI or OpenAlex link to obtain the source. The 141 studies without converted full text were screened and extracted from title and abstract; their `not stated` values mean the abstract did not state the field, not that the study does not address it.
