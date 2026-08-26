# ---------------------------------------------------------------------------
# capture_model_metadata.R — the method parameters of every model used.
#
# The protocol requires the exact model name, quantisation, temperature and
# seed for every inference run, on the grounds that these are method
# parameters and belong in the supplementary material rather than being
# treated as implementation detail.
#
# Quantisation in particular cannot be written from memory. The two ensemble
# models are both 4-bit but under DIFFERENT schemes -- gemma4:e4b is Q4_K_M
# and llama3:latest is Q4_0 -- and a methods paragraph saying "both 4-bit
# quantised" would be describing a configuration that does not exist. This
# reads the values from the serving runtime and writes them out for Module 09
# to interpolate.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(readr)
  library(jsonlite); library(httr); library(purrr)
})
source(here::here("R", "config.R"))

OUT_CSV <- here::here(DIR_DERIVED, "model_metadata.csv")

r <- httr::GET(paste0(OLLAMA_URL, "/api/tags"), httr::timeout(30))
if (httr::status_code(r) != 200)
  stop("Ollama did not respond at ", OLLAMA_URL, "; cannot capture model metadata.")
tags <- httr::content(r, "parsed", "application/json")$models

meta <- purrr::map_dfr(tags, function(m) {
  d <- m$details %||% list()
  tibble::tibble(
    model         = m$name %||% NA_character_,
    family        = d$family %||% NA_character_,
    parameter_size= d$parameter_size %||% NA_character_,
    quantisation  = d$quantization_level %||% NA_character_,
    context_length= if (is.null(d$context_length)) NA_integer_ else as.integer(d$context_length),
    size_gb       = round((m$size %||% NA_real_) / 1e9, 2),
    modified      = m$modified_at %||% NA_character_)
})

# Roles, so the supplement says what each model was actually used for.
roles <- tibble::tribble(
  ~model,             ~role,
  ENSEMBLE_MODELS[1], "screening ensemble; geography gate; country attribution; extraction (primary)",
  ENSEMBLE_MODELS[2], "screening ensemble",
  "qwen2.5:7b",       "extraction cross-model check (20% subsample); dropped from screening ensemble 2026-08-22")

used <- meta |>
  dplyr::inner_join(roles, by = "model") |>
  # Every deployed run is at OLLAMA_TEMPERATURE with OLLAMA_SEED. The one
  # exception is extraction run 2, which deliberately perturbs temperature so
  # that self-consistency measures something; that value lives in extract.R as
  # EXTRACT_TEMP_PROBE and is recorded in the deviations table, not here.
  dplyr::mutate(temperature = OLLAMA_TEMPERATURE,
                seed = OLLAMA_SEED,
                served_by = "ollama")

stopifnot(NROW(used) == NROW(roles), !any(is.na(used$quantisation)))
readr::write_csv(used, OUT_CSV)

cat("\n=== MODEL METHOD PARAMETERS ===\n")
print(as.data.frame(used |> dplyr::select(model, family, parameter_size, quantisation,
                                          context_length, size_gb, role)))
cat(sprintf("\nDistinct quantisation schemes in the ensemble: %s\n",
            paste(unique(used$quantisation[used$model %in% ENSEMBLE_MODELS]), collapse = ", ")))
cat(sprintf("Wrote %s\n", OUT_CSV))
sessionInfo()
