# ---------------------------------------------------------------------------
# config.R — global parameters for the North Africa HWC automated evidence map.
# Every module sources this file. Do not hard-code these values elsewhere.
# ---------------------------------------------------------------------------

SCOPE_MARINE     <- TRUE

# LANGUAGES is the language set the protocol PLANNED. Realised coverage is
# English-only, and the write-up must say so -- see LANGUAGE_LIMITATION below.
LANGUAGES        <- c("en", "fr", "ar")

# ---------------------------------------------------------------------------
# REALISED LANGUAGE COVERAGE — decided 2026-08-23: proceed English-only.
#
# The French and Arabic cells were planned and executed, but returned
# 2 records (openalex_fr_ALL) and 0 records respectively, out of 65,815.
# That is a term-coverage artifact, not an empirical finding:
#
#   block            English   French   Arabic
#   conflict terms      19        7        6
#   wildlife terms      37        4        5
#   geography cells      6        1        1   (EN per-country; FR/AR pooled)
#
# Three narrow blocks AND-ed together yield almost nothing. Additionally the
# 11 Latin binomials (Sus scrofa, Macaca sylvanus, Caretta caretta, ...) are
# language-independent but live only in WILDLIFE_EN, whose cells carry a
# language=en filter -- so French and Arabic papers using scientific
# nomenclature were excluded by the filter rather than by relevance.
#
# CONSEQUENCE FOR MODULE 07: absences in the evidence map are absences in
# ENGLISH-INDEXED literature. They must be reported as such. A thin cell for
# Algeria or Morocco cannot be claimed as an evidence gap without this
# qualifier, since Maghreb wildlife research is substantially francophone.
# State this in the Module 07 narrative, the Module 09 limitations, and the
# abstract.
LANGUAGE_LIMITATION <- paste(
  "Search and screening were English-language only. French and Arabic query",
  "cells were executed but returned 2 and 0 records respectively, reflecting",
  "narrower non-English term blocks rather than an absence of literature.",
  "Evidence gaps reported here are gaps in English-indexed literature.")
COUNTRIES        <- c("Tunisia", "Algeria", "Morocco", "Libya", "Egypt")
YEAR_FROM        <- 1990
INCLUDE_GREY     <- TRUE

# Local ensemble served by Ollama.
# Two genuinely different training lineages:
#   gemma4:e4b     (Google, Gemma family, ~9.6 GB)
#   llama3:latest  (Meta,   Llama family, ~4.7 GB)
# Served sequentially — 16 GB unified memory cannot hold both at once.
#
# qwen2.5:7b was added on 2026-08-13 to lift recall from 0.893 on
# Bannach-Brown_2019, and REMOVED on 2026-08-22 because it never did.
# Leave-one-model-out ablation, recomputed from the cached 04a votes
# (reproduces the committed metrics exactly, tp=25 fp=23 fn=3 tn=147):
#
#   config                     all 198        abstract-present (n=107)
#   gemma+llama+qwen           sens 0.893     sens 1.000  spec 0.926
#   gemma+llama  (no qwen)     sens 0.893     sens 1.000  spec 0.926
#
# The two confusion matrices are identical: under the UNION rule qwen is
# the most conservative voter (sens 0.607 alone) and never contributes an
# include the other two miss. What actually fixed recall was restricting
# to abstract-present records (0.893 -> 1.000), not the third model.
#
# Corroborated on the real corpus: across the 34,448 HWC records qwen had
# scored before the 2026-08-22 crash, it uniquely pulled in 5 records out
# of 392 includes — and all 5 fail the Context criterion (Sri Lanka,
# Europe, South Africa, Gibraltar, South Asia). See Module 09 deviations.
ENSEMBLE_MODELS  <- c("gemma4:e4b", "llama3:latest")
DECISION_RULE    <- "union"   # include if ANY model includes — maximises recall
N_RUNS_PER_ITEM  <- 2         # self-consistency at temperature 0
TARGET_RECALL    <- 0.95      # benchmark-calibrated threshold

# Paths — resolved with here::here() at call sites, never absolute.
DIR_RAW          <- "data/raw"
DIR_DERIVED      <- "data/derived"
DIR_EXTERNAL     <- "data/external"
DIR_BENCHMARKS   <- "data/benchmarks"
DIR_FIGURES      <- "figures"
DIR_TABLES       <- "tables"
DIR_OUTPUT       <- "output"
DIR_LOGS         <- "logs"

# Inference cache — knits read from here, never re-run models.
DIR_CACHE_INFERENCE <- "cache/inference"

# Ollama local server (OpenAI-compatible endpoint on /v1, native on /api).
OLLAMA_URL          <- "http://localhost:11434"
OLLAMA_OPENAI_URL   <- "http://localhost:11434/v1"
OLLAMA_TEMPERATURE  <- 0
OLLAMA_SEED         <- 42L

# API endpoints (no paid services).
# Unpaywall is intentionally omitted: OpenAlex already ingests Unpaywall's OA
# data on every work record (best_oa_location.pdf_url). Dropping the direct
# Unpaywall dependency removes the ToS-mandated email contact requirement
# with negligible impact on OA retrieval for a scoping study.
OPENALEX_BASE    <- "https://api.openalex.org"
CROSSREF_BASE    <- "https://api.crossref.org"
CORE_BASE        <- "https://api.core.ac.uk/v3"
GROBID_URL       <- "http://localhost:8070"

CORE_API_KEY     <- Sys.getenv("CORE_API_KEY", unset = NA_character_)

# Deduplication thresholds.
DEDUP_TITLE_JW   <- 0.95   # Jaro-Winkler similarity on normalised titles
DEDUP_YEAR_TOL   <- 1L     # ±1 year

# Reliability floor for extraction fields entering the headline analysis.
FIELD_RELIABILITY_MIN <- 0.70

# Embedding model available locally (Ollama). Reserved for Module 03
# near-duplicate detection above the Jaro-Winkler baseline.
EMBEDDING_MODEL  <- "nomic-embed-text:latest"

# OCR — protocol's default was `ocrmac` (Apple Vision) with `tesseract`
# as fallback. User also reports Baidu PaddleOCR ("Unlimited-OCR") available;
# Module 05 will test all three on a small scanned sample and pick per language.
OCR_ENGINES      <- c("ocrmac", "tesseract", "paddleocr")
