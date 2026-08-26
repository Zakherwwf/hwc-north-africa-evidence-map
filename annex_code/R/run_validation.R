# ---------------------------------------------------------------------------
# run_validation.R — Module 04a orchestrator.
#
# Session-scoped default: 1 SYNERGY dataset (Nagtegaal, 5% prevalence
# matches our expected HWC corpus), 200 stratified records, 1 prompt
# polarity, ensemble = gemma4:e4b + llama3:latest, N_RUNS_PER_ITEM = 2.
# Total: 800 inferences.
#
# Scale to full protocol by editing DATASETS / N_SAMPLE / POLARITIES /
# N_RUNS below; framework and cache are identical.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(here); library(dplyr); library(tibble); library(jsonlite); library(digest)
})

readRenviron("~/.Renviron")
source(here::here("R", "config.R"))
source(here::here("R", "search.R"))       # for .oa_get + credit guard
source(here::here("R", "validate.R"))
source(here::here("R", "classifier.R"))

DATASETS   <- c("Bannach-Brown_2019")  # Nagtegaal has broken CSV requiring Dataverse-fetching; deferred.
N_SAMPLE   <- 200L
POLARITIES <- c("affirmative", "antonymic", "negation")
MODELS     <- ENSEMBLE_MODELS
N_RUNS     <- N_RUNS_PER_ITEM

results_all <- list()

for (ds in DATASETS) {
  message("\n=== Dataset: ", ds, " ===")
  ids  <- load_synergy_ids(ds)
  message("  loaded ", NROW(ids), " ids; prevalence=",
          round(mean(ids$label == 1), 4))

  samp <- stratified_sample(ids, N_SAMPLE)
  message("  sample: ", NROW(samp),
          " (pos=", sum(samp$label == 1),
          ", neg=", sum(samp$label == 0), ")")

  meta <- fetch_openalex_meta(samp$record_id,
                              cache_key = paste0(ds, "_n", N_SAMPLE))
  message("  fetched metadata for ", NROW(meta), " records from OpenAlex")

  work <- samp |> dplyr::inner_join(meta, by = "record_id") |>
    dplyr::filter(!is.na(title))
  message("  classifiable: ", NROW(work), " records")

  criteria <- SYNERGY_CRITERIA[[ds]]
  for (pol in POLARITIES) {
    message("  polarity: ", pol)
    t0 <- Sys.time()
    preds <- vector("list", NROW(work))
    for (i in seq_len(NROW(work))) {
      preds[[i]] <- classify_record(
        record_id     = work$record_id[i],
        title         = work$title[i],
        abstract      = work$abstract[i],
        criteria_text = criteria,
        models        = MODELS,
        polarity      = pol,
        n_runs        = N_RUNS
      )
      if (i %% 25 == 0)
        message("    [", i, "/", NROW(work), "] elapsed ",
                round(as.numeric(Sys.time() - t0, units = "secs")), "s")
    }
    t1 <- Sys.time()
    message("  done in ", round(as.numeric(t1 - t0, units = "secs")), "s")

    # Reduce ensemble → single boolean prediction per record.
    ens_pred <- vapply(preds, ensemble_decision, logical(1))
    results_all[[length(results_all) + 1]] <- tibble::tibble(
      dataset   = ds,
      polarity  = pol,
      record_id = work$record_id,
      label     = work$label,
      pred      = ens_pred
    )
  }
}

all_preds <- dplyr::bind_rows(results_all)
dir.create(here::here(DIR_DERIVED), showWarnings = FALSE, recursive = TRUE)
saveRDS(all_preds, here::here(DIR_DERIVED, "validation_predictions.rds"))

metrics <- all_preds |>
  dplyr::group_by(dataset, polarity) |>
  dplyr::summarise(compute_metrics(pred, label), .groups = "drop")
saveRDS(metrics, here::here(DIR_DERIVED, "validation_metrics.rds"))
readr::write_csv(metrics, here::here(DIR_DERIVED, "validation_metrics.csv"))

cat("\n=== ENSEMBLE metrics (per dataset x polarity) ===\n")
print(metrics)

cat(sprintf("\nOpenAlex credits used this session: %d / %d cap\n",
            .oa_env$credits_used, .OPENALEX_CREDIT_CAP))
