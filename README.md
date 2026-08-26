# Automated Evidence Mapping of Human–Wildlife Conflict & Coexistence Research in North Africa

[![R Environment: renv](https://img.shields.io/badge/R%20Environment-renv-blue.svg)](annex_code/renv.lock)
[![Inference: Local Ollama](https://img.shields.io/badge/Inference-Local%20LLMs%20(Ollama)-orange.svg)](annex_code/compute_environment.md)
[![Data: Open Access](https://img.shields.io/badge/Data-Open%20Access%20Bibliographic-green.svg)](annex_data/)
[![Design: Systematic Evidence Map](https://img.shields.io/badge/Design-Automated%20Evidence%20Map-purple.svg)](annex_code/RUN_automated_evidence_map_prompt.md)

This repository contains the complete codebase, data assets, execution logs, and replication materials for an end-to-end **automated systematic evidence map** examining human–wildlife conflict and coexistence literature across Algeria, Egypt, Libya, Morocco, and Tunisia.

All screening decisions and structured data extractions were conducted using a local multi-model Large Language Model (LLM) ensemble validated against external gold-standard benchmarks, with every extracted variable grounded in verbatim source quotes.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Repository Structure](#2-repository-structure)
3. [Pipeline Architecture & Workflow](#3-pipeline-architecture--workflow)
4. [Replication Guide](#4-replication-guide)
   - [Option A: Quick Analytical Reproduction (From Data)](#option-a-quick-analytical-reproduction-from-data)
   - [Option B: Full End-to-End Execution (From Scratch)](#option-b-full-end-to-end-execution-from-scratch)
5. [Adapting to Other Research Questions](#5-adapting-to-other-research-questions)
6. [Data Dictionary & Claim Verification](#6-data-dictionary--claim-verification)
7. [Methodological Disclosures & Boundaries](#7-methodological-disclosures--boundaries)
8. [Hardware & Compute Environment](#8-hardware--compute-environment)

---

## 1. Project Overview

Evidence synthesis in conservation science often suffers from geographic and linguistic biases, high manual labor costs, and unmeasured reviewer subjectivity. This project establishes an automated, fully reproducible framework for systematic evidence mapping:

* **Corpus Scale:** 95,546 candidate records retrieved across a multi-source, multi-language, multi-country search matrix (OpenAlex, CORE, Crossref).
* **Deduplication & Screening:** Algorithmic deduplication followed by a local two-model LLM ensemble (`gemma4:e4b` and `llama3:latest`) operating under a recall-maximizing union rule, pre-calibrated against external benchmarks.
* **Full-Text Processing:** Automated open-access retrieval and structured XML conversion via GROBID.
* **Quote-Grounded Extraction:** 20 structured fields extracted per study, requiring exact verbatim string matching against source text to guarantee traceability.
* **Robustness Auditing:** Seven pre-specified sensitivity variants testing whether substantive findings survive classifier decision boundaries and geographic ambiguities.

---

## 2. Repository Structure

```
├── README.md                                # This document
│
├── annex_code/                              # Complete executable pipeline
│   ├── R/                                   # 26 standalone R helper and execution scripts
│   ├── rmd/                                 # 12 sequential pipeline modules (00_setup → 09_outputs)
│   ├── renv.lock                            # Exact pinned versions of all R package dependencies
│   ├── .Rprofile                            # Automatic renv environment activator
│   ├── compute_environment.md               # Hardware specifications and token throughput benchmarks
│   └── RUN_automated_evidence_map_prompt.md # Step-by-step master pipeline specification
│
├── annex_data/                              # All data assets, logs, and verification files
│   ├── included_studies/                    # Row-level registers for all 262 included studies
│   │   ├── included_studies_full.csv        # Complete register (262 rows × 50 columns)
│   │   ├── extraction_evidence_trail.csv    # 4,940 extracted values with verbatim quote grounding
│   │   ├── included_studies_bibliography.md # Human-readable bibliographic register
│   │   └── README.md                        # Row-level verification guide
│   ├── tables/                              # 28 summary result tables (CSV)
│   ├── derived_csv/                         # 12 intermediate dataset tables (CSV)
│   ├── verification/                        # External DOI audits, duplicate census, and grounding records
│   ├── logs/                                # 43 timestamped run logs (JSONL and plain text)
│   └── search_strategy_full.md              # Complete Boolean query strings across all languages
│
├── annex_reports/                           # Knitted standalone HTML reports for every module
├── annex_output/                            # Generated synthesis outputs and structured abstracts
└── figures/                                 # 22 publication-ready figure files (PNG + vector SVG)
```

---

## 3. Pipeline Architecture & Workflow

The pipeline executes as a sequence of independent, fully documented modules in `annex_code/rmd/`:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   00_setup   │ ──> │ 01_protocol  │ ──> │  02_search   │ ──> │03_deduplicate│
│ Environment  │     │ Eligibility  │     │ OpenAlex/    │     │ Exact DOI +  │
│ Verification │     │  Framework   │     │  CORE Queries│     │ Jaro-Winkler │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
                                                                       │
┌──────────────┐     ┌──────────────┐     ┌──────────────┐             │
│ 06_extract   │ <── │ 05_fulltext  │ <── │ 04b_classify │ <───────────┘
│ Quote-Grounded│    │ PDF Download │     │ Two-Model LLM│   (04a Calibrates
│ 20-Field Run │     │ + GROBID TEI │     │  Screening   │    on Benchmark)
└──────────────┘     └──────────────┘     └──────────────┘
       │
       ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│07_evidencemap│ ──> │  08_figures  │ ──> │  09_outputs  │
│ Synthesis &  │     │ Vector Plots │     │ Methods Text │
│  Robustness  │     │  & Matrices  │     │ & Synthesis  │
└──────────────┘     └──────────────┘     └──────────────┘
```

| Module | Purpose | Key Outputs |
|---|---|---|
| **`00_setup.Rmd`** | Verifies Ollama, GROBID container, API reachability, and package lockfile. | Environment validation report |
| **`01_protocol.Rmd`** | Formulates Population, Concept, and Context (PCC) criteria prior to search. | Protocol specification |
| **`02_search.Rmd`** | Executes structured multi-source, multi-lingual query matrix. | `annex_data/logs/02_search_*.jsonl` |
| **`03_deduplicate.Rmd`** | Performs exact DOI matching followed by fuzzy title/year deduplication. | Deduplicated corpus ledger |
| **`04a_validate_classifier.Rmd`** | Benchmarks LLMs on external human-labelled datasets under 3 prompt polarities. | Confusion matrices & CIs |
| **`04b_classify.Rmd`** | Executes two-model ensemble screening with union decision rule. | Model agreement & screening ledger |
| **`05_fulltext.Rmd`** | Resolves open-access PDFs and structures XML via GROBID. | Text basis classification |
| **`06_extract.Rmd`** | Extracts 20 categorical/quantitative fields with verbatim source quotes. | `extraction_evidence_trail.csv` |
| **`07_evidence_map.Rmd`** | Evaluates geographic, taxonomic, and conflict-type distributions. | Synthesis tables & robustness ranks |
| **`07b_synthesis.Rmd`** | Synthesizes mitigation effectiveness, damage metrics, and study designs. | Mitigation funnel & gap ledgers |
| **`08_figures.Rmd`** | Renders all analytical figures in high-resolution PNG and vector SVG formats. | `figures/*.png`, `figures/*.svg` |
| **`09_outputs.Rmd`** | Compiles structured methods, summary abstracts, and deviation records. | Summary text & protocol ledgers |

---

## 4. Replication Guide

### Option A: Quick Analytical Reproduction (From Data)

To verify all statistical calculations, regenerate summary tables, and reproduce all figures directly from the deposited data (without re-running LLM inference):

1. **Clone the repository:**
   ```bash
   git clone <repository_url>
   cd <repository_directory>
   ```

2. **Restore the locked R environment:**
   ```bash
   R -e 'renv::restore()'
   ```

3. **Render analytical modules & synthesize outputs:**
   Open any module in `annex_code/rmd/` (e.g., `07_evidence_map.Rmd`, `07b_synthesis.Rmd`, `08_figures.Rmd`, `09_outputs.Rmd`) in RStudio or render via command line:
   ```bash
   R -e "rmarkdown::render('annex_code/rmd/07_evidence_map.Rmd')"
   R -e "rmarkdown::render('annex_code/rmd/08_figures.Rmd')"
   R -e "rmarkdown::render('annex_code/rmd/09_outputs.Rmd')"
   ```

---

### Option B: Full End-to-End Execution (From Scratch)

To re-run the entire pipeline from raw bibliographic searches through LLM classification and full-text extraction:

#### 1. Software & Service Prerequisites
* **R (v4.4+)** with package library restored via `renv::restore()`.
* **[Ollama](https://ollama.com)** (v0.32+) serving local open-weights LLMs:
  ```bash
  ollama pull gemma4:e4b
  ollama pull llama3:latest
  ollama pull qwen2.5:7b
  ollama pull nomic-embed-text:latest
  ```
* **[GROBID](https://github.com/kermitt2/grobid)** (v0.8.1) running in Docker:
  ```bash
  docker run -t --rm -p 8070:8070 grobid/grobid:0.8.1
  ```
* **API Credentials (Free):**
  * OpenAlex API requires no paid subscription.
  * Set your free CORE API key in `~/.Renviron`:
    ```bash
    CORE_API_KEY="your_core_api_key_here"
    ```

#### 2. Execution Order
Execute the R Markdown scripts in `annex_code/rmd/` strictly in numerical sequence (`00_setup.Rmd` → `09_outputs.Rmd`). Every module logs timestamped outputs to `annex_data/logs/` and caches serialized RDS data in `data/derived/`.

---

## 5. Adapting to Other Research Questions

The architecture is structured as a **domain-agnostic evidence-synthesis engine**. To adapt this pipeline to another research field (e.g., *mangrove restoration in Southeast Asia*, *avian wind-turbine mortality*, *zoonotic spillover risk*):

1. **Configure Search Blocks (`annex_code/R/search_terms.R` & `config.R`):**
   * Update the geographic entities (`COUNTRIES`), target concept strings (`CONFLICT_TERMS`), and taxonomic/topical keywords (`WILDLIFE_TERMS`).
2. **Define Eligibility Prompts (`annex_code/R/classifier.R`):**
   * Tailor the system prompt with your domain's explicit inclusion criteria and edge-case handling rules.
3. **Calibrate on Domain Benchmarks (`annex_code/rmd/04a_validate_classifier.Rmd`):**
   * Test your model ensemble against a sample of human-screened studies from your field to calculate baseline sensitivity and specificity.
4. **Configure Extraction Schema (`annex_code/R/extract.R`):**
   * Define the JSON schema and prompt fields corresponding to your extraction needs (e.g., intervention types, quantitative outcomes, sample sizes).
5. **Execute Synthesis (`annex_code/rmd/07_evidence_map.Rmd`):**
   * Adjust cross-tabulations and visualization parameters to map your domain's core variables.

---

## 6. Data Dictionary & Claim Verification

Every factual claim and statistic is backed by serialized data. Use this guide to audit individual numbers:

| Metric / Finding | Exact Value | Verification Source |
|---|---|---|
| Total Retrieved Records | 95,546 | `annex_data/derived_csv/record_flow.csv` |
| Analytic Included Set | 262 studies | `annex_data/included_studies/included_studies_full.csv` |
| Screening Sensitivity (95% CI) | 0.893 (0.718–0.977) | `annex_data/derived_csv/validation_metrics.csv` |
| Inter-Model Agreement (κ / PABAK) | 0.343 / 0.986 | `annex_data/tables/04b_model_agreement.csv` |
| Marine vs. Terrestrial Focus | 116 marine / 63 terrestrial | `annex_data/tables/07_marine_terrestrial.csv` |
| Bycatch Share | 59 of 138 conflict-coded studies | `annex_data/tables/07_conflict_type.csv` |
| Mitigation Evaluation Endpoint | 22 studies | `annex_data/included_studies/studies_reporting_outcome_direction.csv` |
| Studies with In-Country Author | 54.1% (45.9% non-local) | `annex_data/tables/07_authorship_equity.csv` |
| Full-Text Retrieval Rate | 52.0% (121 studies) | `annex_data/derived_csv/retrieval_by_country.csv` |

### Row-Level Evidence Auditing (`annex_data/included_studies/`)
* **To inspect study references:** Open `included_studies_bibliography.md`.
* **To audit specific extracted data points:** Open `extraction_evidence_trail.csv`. Filter by `openalex_id` and `field` to see the final value, the two models' independent outputs, and the verbatim source quote.

---

## 7. Methodological Disclosures & Boundaries

To uphold scientific rigor, the following methodological boundaries are explicitly documented:

1. **Search Construction Asymmetry:** Search strings in French (4 terms) and Arabic (5 terms) were substantially narrower than English (38 terms), and Latin binomials were placed in English-filtered cells. Consequently, regional absences reflect **English-indexed gaps**, not necessarily an absence of regional-language scholarship.
2. **Deferred Records:** 4,755 records lacking abstracts and 104 inference failures were categorized as **deferred, not excluded**, avoiding artificial inflation of precision.
3. **Extraction Reliability Floor:** Five extraction fields (including subnational location and study design) fell below reliability thresholds during quote validation and were excluded from final synthesis.
4. **Duplicate Record Handling:** Nine duplicate record pairs with conflicting DOIs across preprint and publisher repositories were discovered post-hoc and audited under robustness variant *(g)*.

---

## 8. Hardware & Compute Environment

All model inference was performed locally without cloud dependencies.

* **Reference Hardware:** Apple MacBook Pro (M1 Pro, 8 performance / 2 efficiency cores, 16 GB unified memory).
* **Model Footprint:** Models were served sequentially via Ollama to respect the 16 GB memory boundary (`gemma4:e4b` occupies ~9.6 GB; `llama3:latest` occupies ~4.7 GB).
* **Inference Parameters:** `temperature = 0`, `seed = 42L`, `num_ctx = 8192`.
* **Full Benchmark Details:** See [`annex_code/compute_environment.md`](annex_code/compute_environment.md) for measured token-per-second throughput and context window allocations.

---

## License & Attribution

This repository is distributed under open-source and open-data standards to facilitate transparent verification and adaptation. When using or adapting this pipeline, please cite the underlying methodology and data sources as documented in the repository.
