# Grounding denominators: which values count as "stated"

Two defensible definitions exist, they differ by 43 rows, and they give different
headline numbers. This note fixes the convention used in the paper.

## The disagreement

`extraction_evidence_trail.csv` has 4,940 field-value rows. The value `not stated`
appears 2,561 times and is unambiguously an absence. The value `not measured`
appears 43 times, all in `outcome_direction`, and is ambiguous:

| definition | stated values | grounding on stated |
|---|---|---|
| `not measured` is an ABSENCE (excluded) | 2,336 | 81.7% |
| `not measured` is a STATED value (included) | 2,379 | 80.2% |

The Phase 1 claim audit flagged this as its only mismatch (claims 44 and 45,
delta 43 rows). It is a definitional disagreement, not an arithmetic error.

## The convention adopted

**`not measured` counts as a stated value.** The paper and all annex tables use
the 2,379 denominator and report 80.2%.

Reasoning: "not measured" is a substantive determination about the study — the
study reports an outcome but did not measure its direction — whereas "not stated"
records that the extraction found nothing to report. The former is a finding; the
latter is a gap in the record. Treating a finding as an absence would remove it
from the denominator of a measure that is supposed to test whether extracted
findings are grounded in text.

Note that this is the *less* flattering choice. All 43 `not measured` values are
ungrounded by construction (a study that did not measure something contains no
sentence saying so), so including them lowers the reported grounding rate from
81.7% to 80.2%. The convention was chosen for defensibility, not for the number.

## Where this matters

`mitigation_outcome_measured` grounding is 30.8% on n = 91 stated values. This is
one of the two fields the mitigation funnel rests on, and it is reported in the
manuscript with its denominator named rather than pooled into a single
corpus-wide figure.
