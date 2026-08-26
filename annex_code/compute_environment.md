# Compute environment

Captured 2026-08-25T17:55:03Z on the machine that ran the pipeline.

## Host

| item | value |
|---|---|
| Model | MacBookPro18,3 |
| CPU | Apple M1 Pro |
| Cores (perf/eff) | 8/2 |
| Unified memory | 16 GB |
| OS | macOS 26.6.1 (build 25G76) |
| Architecture | arm64 |
| GPU | Apple M1 Pro |
| GPU cores | 16 |
| Ollama | ollama version is 0.32.15 |
| R | R version 4.4.1 (2024-06-14) |

There is no discrete VRAM: Apple Silicon uses unified memory, so model
weights and system memory draw on the same pool. This is the constraint
that forced the ensemble to be served sequentially rather than
concurrently, and it is why a third model was dropped.

## Inference throughput

Measured on the host above with an identical prompt to each model, temperature 0,
`num_ctx` 8192. Prefill is prompt processing; generation is token emission.
Load duration is the cold model load into unified memory.

| model | prefill tok/s | generation tok/s | load s |
|---|---|---|---|
| `gemma4:e4b` | 158.0 | 34.0 | 0.0 |
| `llama3:latest` | 221.8 | 34.0 | 3.9 |
| `qwen2.5:7b` | 197.6 | 26.4 | 2.7 |

Sequential serving is forced by the 16 GB unified memory: `gemma4:e4b` alone
occupies 9.6 GB. Each model swap pays the load cost above, which is why every
module loops model-major rather than record-major.

## Context windows actually used

| stage | model | native context | `num_ctx` set | input cap |
|---|---|---|---|---|
| Screening | gemma4:e4b + llama3:latest | 131,072 / 8,192 | 8,192 | title + abstract |
| Geographic verification | gemma4:e4b | 131,072 | 8,192 | title + abstract |
| Country attribution | gemma4:e4b | 131,072 | 8,192 | title + abstract |
| Extraction | gemma4:e4b | 131,072 | 8,192 | 24,000 chars (~6,000 tokens) |
| Cross-model extraction | qwen2.5:7b | 32,768 | 8,192 | 24,000 chars |

The 8,192-token window was **our configuration, not a model limit**. Reviewer 2
raises the concern that GROBID TEI can exceed LLaMA-3-8B's 8,192-token window
and truncate: extraction never used llama3, and `gemma4:e4b` offers 131,072
tokens natively.

Truncation nonetheless occurred, because extraction targets the methods and
results sections and caps input at 24,000 characters. Of 260 extracted records:

| text basis | n |
|---|---|
| methods/results, untruncated | 95 |
| methods/results, truncated at 24,000 chars | 4 |
| whole body fallback (no section heads found), untruncated | 4 |
| whole body fallback, truncated | 13 |
| title + abstract (no full text retrievable) | 144 |

So 17 of 116 full-text records (14.7%) were truncated. Raising `num_ctx` to the
model's native 131,072 would remove the cap at a throughput cost that was not
paid here; this is a disclosed limitation, not an oversight.
