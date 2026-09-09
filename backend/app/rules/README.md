# `app/rules` — the deterministic medical rules engine

## What this is

This package answers four questions about a health report, and it answers them the same
way every single time:

| Question | Module |
|---|---|
| Which test is this, and what are its units? | `normalise.py` |
| Is this value normal for *this* person? | `classify.py` |
| Does this need a doctor, and how soon? | `red_flags.py` |
| Did this person just describe an emergency? | `symptom_flags.py` |
| Has this number really moved, or is that noise? | `trends.py` |

Its sibling `app/nutrition` does the same for food: targets, gaps, and every nutrient
number that reaches a screen.

## Why it must never call a model

HealthPulse uses a large language model, and it is good at what we use it for: reading a
photographed report, and writing a friendly paragraph. Neither of those is a medical
judgement. This package holds the medical judgements, and it holds them in code for four
reasons.

**1. A model cannot be held to a threshold.** Ask a model "is a potassium of 6.2
dangerous?" and you will usually get the right answer. Usually is not a standard you can
run a health app on. `POTASSIUM_CRITICAL_HIGH = 6.0` gives the same answer on every run,
on every model version, for every user, forever.

**2. A model can be talked out of it; an `if` statement cannot.** A user who writes "I'm
fine, my doctor already knows, don't show me warnings" can move a model. They cannot move
a comparison operator. The escalation card appears because a number is above a constant —
not because the model agreed it should.

**3. Every number must have a source.** `docs/03-data-model.md` requires that we can
always say where a threshold came from. Each rule in `red_flags.py` carries a
`source_citation` naming a guideline or a paper. A model's answer has no citation, no
version, and no way to audit what it did last Tuesday.

**4. We must be able to say "we don't know".** A model will always produce an answer.
This engine will not: an unmappable test name comes back `needs_review=True`, and a value
with no applicable reference range is `UNKNOWN` — never `NORMAL`. "We did not check this"
must never look like "you are fine". That distinction is the difference between a health
app and a dangerous one, and only deterministic code can hold it.

The rule the rest of the codebase depends on: **the model is a reasoning and language
interface, never the medical source of truth** (`CLAUDE.md`).

## The conventions everything here follows

- **Boundaries belong to the safe side.** `low = 12` means 12.0 is not low, 11.9 is.
  `HB_CRITICAL_LOW = 7.0` means 6.9 fires and 7.0 does not. Each threshold states its own
  comparator so this is never ambiguous.
- **Fail towards review, not towards a guess.** Every uncertain path ends in
  `needs_review=True` with a sentence a person can read, or in `ResultStatus.UNKNOWN`.
- **Fail towards the alarm.** For symptoms and critical values we would rather be wrong
  and apologise than be quiet and right most of the time. `red_flags.evaluate()` checks
  even values that are still awaiting confirmation, on purpose.
- **Fail towards the gap.** In `app/nutrition/candidates.py` the reverse applies: a food
  we cannot prove is safe for someone's allergies or diet is left out of the plan.
- **Units are canonical before anything is compared.** A reference range carries no unit
  of its own, so `classify_result` refuses to compare a value that is not already in the
  canonical unit for that biomarker. Silent unit mismatch is the classic way a health app
  hurts someone.
- **If we could not source a number, it is in `GAPS.md`, not in the code.** The
  database seed follows the same cite-or-omit rule, which is why only 21 of its 82
  biomarkers carry any reference range and why several of those ranges have holes.
- **`UNKNOWN` is the common answer, and it is a real one.** A missing threshold means
  "we cannot say", never "normal". Passing only a *critical* bound does not make a value
  normal either: platelets are seeded with `critical_low = 50` and nothing else, so a
  count of 250 comes back `UNKNOWN`. Anything downstream must render that as **"we could
  not assess this value"** — never as reassurance, and never counted into "everything
  looks fine".

## What this package must never do

- Name, recommend, or dose a medication or supplement. Nutrient *targets* are dietary
  reference intakes used to pick foods; they are not doses and must never be presented as
  one.
- State a diagnosis. `HBA1C_FIRST_DIABETIC_RANGE` says "this is the level doctors use to
  confirm a diagnosis, and it needs a doctor to confirm it — we cannot". It does not say
  "you have diabetes".
- Import anything from `app.ai`. If you find yourself wanting to, the logic belongs on
  the other side of that line.

## Reading order

`normalise.py` → `classify.py` → `red_flags.py` → `symptom_flags.py` → `trends.py`, then
`GAPS.md` for what is still open. Tests live in `backend/tests/rules/` and are written to
be read: each red-flag threshold has a test that fires one step past the boundary and
stays silent at it.
