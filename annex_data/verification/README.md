# External verification of the study register

The reconciliation table in `included_studies/` checks *internal consistency* — that the paper's numbers derive from the exported data. It cannot detect an error present in both. This directory reports the *external* checks, run against CrossRef and against the register's own contents.

## 1. DOI and title verification — passes

All 230 DOIs in the register were resolved against the CrossRef API (not sampled — a full census).

| Check | Result |
|---|---|
| Registered in CrossRef | 218 / 230 |
| Title matches our record | 213 / 218 (97.7%) |
| Publication year matches | 212 / 215 |
| DOIs not in CrossRef | 12 (Zenodo, ResearchGate, figshare, regional publishers — DataCite/other registries, not errors) |

The 5 apparent title mismatches are all markup artefacts — CrossRef returns embedded `<i>` and `<scp>` tags around species names, e.g. `Macaca sylvanus`, which our stripped titles do not carry. No substantive mismatch was found. **No case was found of a DOI pointing to a different paper than the one recorded.**

File: `doi_verification_census.csv`

## 2. Deduplication failure — 9 duplicate records, a real defect

Nine pairs of records in the 262-study analytic set are the same work counted twice. The deduplication stage did not catch them because in each case the two records carry **different DOIs**, and DOI equality was the matching key.

Three distinct mechanisms, three pairs each:

| Mechanism | Example |
|---|---|
| Cross-source: an OpenAlex record and a CORE record for the same paper, where the CORE record carries no DOI | "Shelf life: neritic habitat use of a turtle population…" |
| Preprint and version-of-record with separate DOIs | "Ghost Gear in the Gulf of Gabès" — `10.20944/preprints…` and `10.3390/su16188003` |
| The same document deposited twice in Zenodo under two DOIs | IPBES Sustainable Use Assessment Chapter 4 |

Effect on the published numbers, keeping the version of record in each pair:

| Quantity | Published | Deduplicated | Δ |
|---|---|---|---|
| Analytic set | 262 | 253 | −9 |
| Full text converted | 121 | 119 | −2 |
| Bycatch studies | 59 | 53 | −6 |
| Studies reporting outcome direction | 22 | 21 | −1 |
| Tunisia | 81 | 76 | −5 |
| Egypt | 75 | 72 | −3 |
| Libya | 31 | 29 | −2 |
| Morocco / Algeria / crop damage / competition | unchanged | unchanged | 0 |

The duplicates are **not randomly distributed**: they are concentrated in marine bycatch and in Tunisia — precisely the categories carrying the paper's headline claims. Six of the nine are marine studies.

**Which conclusions survive:** every one of them, but two are weakened.

- Bycatch remains the largest stated conflict type by a wide margin (53 vs 20 for crop damage). The claim holds.
- The mitigation funnel endpoint moves from 8.4% to 8.3%. Unaffected.
- Tunisia and Morocco become **tied at 76** rather than Tunisia leading by 5. The paper already reports "Tunisia leads is not a finding" because it fails under two of five robustness variants; deduplication removes the headline margin as well, which strengthens that stated non-finding rather than contradicting it.
- Crop damage, competition for resources, Morocco and Algeria counts are entirely unaffected.

File: `duplicate_pairs_found.csv`, `impact_of_duplicates_on_headline_numbers.csv`

## 3. Four global assessments should probably not be in the analytic set

Four records are global or multi-region documents with no North Africa-specific study: two IPBES Sustainable Use Assessment chapters, an EU wind-energy deliverable on seabird collision risk, and a preprint synthesis on shark conservation. All four sit in geographic tier `C_asserted_no_evidence` — the pipeline's own weakest tier, meaning no in-text evidence corroborating the country attribution was found.

This is **already covered** by the paper's robustness variant (f), which excludes tier C entirely and re-derives the whole map. It is not a hidden problem, but it is a reason to read the tier-C-excluded row of Table 5 as the more defensible estimate.

## 4. Quote grounding — the honest picture

Of 4,940 extracted field values, 2,336 state a value and 2,604 record "not stated". Grounding applies only to the former.

| | Rate |
|---|---|
| Stated values with a verbatim supporting quote | **81.7%** |
| Stated values where both models independently agreed | 94.1% |

Grounding varies sharply by field, and **the two fields carrying the mitigation-funnel argument are the worst**:

| Field | n stated | Grounded |
|---|---|---|
| `compensation_scheme_discussed` | 140 | **4.3%** |
| `mitigation_outcome_measured` | 91 | **30.8%** |
| `mitigation_tested` | 103 | **38.8%** |
| `damage_metric_reported` | 202 | 58.9% |
| `conflict_type` | 154 | 97.4% |
| `sample_size` | 91 | 98.9% |

Descriptive fields — species, country, conflict type, sample size, years — ground at 93–99% and can be relied on. The mitigation fields ground poorly because a *negative* determination ("this study did not test a mitigation") has no sentence to quote; the model is reporting an absence, which is unquotable by construction. That is a defensible reason, but it means the funnel's intermediate steps rest on model judgement rather than on quotable text, and should be read as weaker evidence than the paper's descriptive counts.

File: `grounding_by_field_stated_values.csv`

## What this audit did not check

Nobody re-read the 262 papers. Whether a study coded `bycatch` is *substantively* about bycatch is checkable from the grounding quote in `extraction_evidence_trail.csv`, but no human has done it at scale. The 96.2% cross-model consistency measures reproducibility between two models, not correctness against a human reading — and two models sharing a bias would agree with each other while both being wrong. The external human benchmark reported in the paper (Table 1) covers *screening*, not extraction.


## R1 revision: validation of reviewer responses (added at revision)

`R1_validation_record.csv` records the independent check of every claim made in
the revision, including the seven self-corrections from the Phase 1 audit. Each
row names the file that was read to check it and the verdict.

Two findings changed the manuscript beyond what the response document proposed:

**A ranking claim was overstated and has been corrected.** The revision asserted
that "Algeria is last under every area and count denominator". It is not:
`denominator_rank_comparison.csv` puts Libya last by raw count and by total land
area. Algeria is last under the two agricultural denominators only. The defensible
claim — that Algeria is in the bottom two under all five denominators tested — is
what the manuscript now says.

**An affiliation resolution rate was conflated with an author resolution rate.**
The response reported "249 of 262 records resolve (95.0%)" in answer to a question
about in-country authorship. 249/262 is the rate at which *author names* resolve.
Affiliation *countries* resolve for 207/262 (79.0%), and it is that smaller set
that forms the denominator of every authorship percentage in the paper. The
manuscript already qualified these percentages as applying to "studies with
resolvable affiliations" but never gave the number; it now does.

`grounding_definition_note.md` fixes the convention for which extracted values
count as "stated", which was the sole mismatch in the Phase 1 claim audit. The
convention adopted is the one that lowers the reported grounding rate, from 81.7%
to 80.2%. `grounding_by_field_stated_values.csv` has been regenerated under it and
now totals 2,379 stated values.
