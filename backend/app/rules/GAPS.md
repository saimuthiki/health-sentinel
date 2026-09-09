# Open clinical questions — for a clinician to fill in

This file exists because the alternative is worse. Where the rules engine needed a
number and we could not source one with confidence, we **did not invent it**. Each item
below names what is missing, what the code does in the meantime, and what a clinician
needs to decide.

Nothing here is a bug. It is the honest edge of what a deterministic engine written
without clinical sign-off can claim.

**How to close an item:** replace the constant named below, put the real citation in the
matching `SOURCE_*` string, and delete the item from this file in the same commit.

---

### G1 — Fasting glucose escalation at 300 mg/dL
`app/rules/red_flags.py` → `GLUCOSE_FASTING_CRITICAL_HIGH = 300`

The 300 mg/dL trigger comes from the product brief (`docs/04-ai-pipeline.md`), not from a
clinical guideline. Published laboratory critical limits for glucose are typically higher
(around 500 mg/dL in adults), and the diagnostic threshold is far lower (126 mg/dL
fasting, ADA). 300 sits between the two and was chosen as an escalation point, not as a
critical value.

**Needed:** confirm 300 mg/dL as the "contact a doctor today" trigger, or replace it.
Also confirm whether random and post-prandial glucose should have their own triggers —
today only `GLUCOSE_FASTING` has one, so a random glucose of 450 mg/dL raises **no**
red flag.

### G2 — Platelet escalation at 50,000/µL
`app/rules/red_flags.py` → `PLATELETS_CRITICAL_LOW = 50` (units of 10³/µL)

Spontaneous bleeding risk rises sharply below 10,000–20,000/µL; 50,000 is more cautious
than most transfusion guidance. Deliberately cautious, but it will produce urgent cards
for stable chronic thrombocytopenia.

**Needed:** confirm 50,000/µL, and decide whether a *stable, already known* low platelet
count should be downgraded to `see_doctor_soon` the way HbA1c is.

### G3 — Creatinine rise: 30% and the 0.1 mg/dL floor
`app/rules/red_flags.py` → `CREATININE_RISE_FRACTION = 0.30`,
`CREATININE_MIN_ABSOLUTE_RISE = 0.1`

KDIGO stage 1 AKI is a rise to ≥1.5× baseline (50%) within 7 days, or ≥0.3 mg/dL within
48 hours. We escalate at 30% deliberately, because our two reports may be months apart
and a slow rise matters too. The 0.1 mg/dL absolute floor exists to stop rounding noise
(0.6 → 0.8 mg/dL is a 33% "rise" that may be one decimal place of assay wobble).

**Needed:** confirm 30%, confirm the absolute floor, and decide whether the comparison
should be time-limited (e.g. ignore a "previous" report older than 12 months).

### G4 — RDA nutrients with no target at all
`app/nutrition/targets.py` → `RDA_TABLE`

This table now mirrors `db/seed/203_rda_targets.sql` row for row and follows the same
cite-or-omit rule, so the nutrients that file omits are omitted here too and
`resolve_target()` returns `None` for them:

- **Dietary fibre.** The planner's GAPS block wants it constantly, and there is no
  target. It is commonly stated per 1,000 kcal rather than as an absolute, and we would
  not guess.
- **Pregnancy and lactation increments.** The `pregnancy` column and its specificity
  rule are implemented and tested with a fixture row, but **no pregnancy row ships**, so
  a pregnant user is resolved against the non-pregnant target for every nutrient.
- **Adults 60+.** The band is 19–59, so an older adult resolves to nothing at all.
- **Children and adolescents**, and vitamins A and C, magnesium, iodine and the
  B-complex.

**Needed:** these figures read off the printed ICMR-NIN 2020 table by a dietitian, added
to the seed file and mirrored here.

### G5 — Assay variation data is generic, not this lab's
`app/rules/trends.py` → `BIOLOGICAL_VARIATION`

The CV values are desirable analytical goals from the published biological-variation
database. The actual CVₐ of the laboratory that ran the user's sample is different and
unknown to us. That makes our reference change values approximate.

**Needed:** either accept generic values (and say so in the UI), or capture the lab's
method per result and hold per-method CVs. Biomarkers **not** in the table — B12,
folate, sodium's clinical relevance, platelets, neutrophils, HbA1c in pregnancy —
currently return "we cannot say whether this change is real", which is safe but unhelpful.

### G6 — The app is adults-only until further notice
`app/nutrition/targets.py` → `ADULT_MIN_AGE = 19`, `ADULT_MAX_AGE = 59`

`resolve_targets()` returns an **empty list** outside 19–59, so no nutrient gaps are
produced for a teenager or for a 65-year-old. On the lab side, `db/seed/GAPS.md`
section 4 item 5 says the same thing: apart from the WHO haemoglobin bands, no
paediatric lab ranges are seeded either.

This is intentional — better nothing than adult numbers applied to a 14-year-old — but
it means **the product must either restrict itself to adults 19–59 or commission the
missing bands.** That is a product decision, not an engineering one.

**Needed:** a decision, then ICMR-NIN rows and paediatric reference ranges by age band
and sex.

### G7 — Red-flag symptom phrase list has not been clinician-reviewed
`app/rules/symptom_flags.py` → `SYMPTOM_RULES`

The eight symptom categories come from `docs/04-ai-pipeline.md`. The *phrases* inside
each category were assembled by the engineering team, including common Indian-English and
Hinglish wording. They have not been reviewed by a clinician, and they are certainly
incomplete for regional languages (Telugu, Tamil, Bengali, Marathi are not covered at
all).

**Needed:** clinician review of each phrase list; a decision on regional-language
coverage; and a decision on symptoms we currently do **not** cover, notably: sudden
severe headache ("worst headache of my life"), seizure, high fever with neck stiffness,
pregnancy bleeding, and testicular pain.

### G8 — Crisis helpline numbers
`app/rules/symptom_flags.py` → the `SYMPTOM_SELF_HARM` advice string

The self-harm message names Tele-MANAS on **14416**. Helpline numbers change, vary by
state, and a wrong number in a crisis message is a serious failure.

**Needed:** the owner to verify the current national and state helpline numbers before
launch, and a decision on where they should live (a config table, not a Python constant,
so they can be corrected without a release).

### G9 — Most biomarkers still cannot be classified
`app/rules/classify.py` classifies against whatever `reference_ranges` rows it is given.
Those rows are owned by `db/` and are now seeded: **28 ranges over 21 of the 82
biomarkers** (`db/seed/202_reference_ranges.sql`). The other **61 can be recognised and
stored but not classified**, and several seeded rows are deliberately incomplete —
platelets carry only `critical_low`, potassium only its two critical values, haemoglobin
no upper limit.

That makes `ResultStatus.UNKNOWN` the ordinary answer rather than an edge case, and it
is handled as a first-class state here: a value the classifier cannot place is
`UNKNOWN`, never `NORMAL`, and `red_flags.critical_status_flags` produces nothing for it
so it is never counted as a clean result either. **The UI must render it as "we could
not assess this value" and must never fold it into a reassuring summary.**

**Needed:** the missing ranges, with citations — see `db/seed/GAPS.md` sections 2 and 3
for the full list. Sodium and calcium critical values are the priority: a sodium of
118 mmol/L is an emergency and there is currently nothing seeded to escalate on, so our
`SODIUM_CRITICAL_LOW` threshold fires only when a sodium result is present in canonical
units. Pregnancy-specific TSH ranges are trimester-dependent and also missing.

### G10 — Censored values ("<0.5", ">1000")
`app/rules/normalise.py` → `parse_value`

A result reported below or above the assay's detection limit is parsed, kept with its
`<` or `>` marker, and marked `needs_review`. Red flags still evaluate it at the boundary
number (see `include_needs_review` in `red_flags.evaluate`), which is conservative on the
high side but **not** on the low side: a TSH reported as "<0.005" is evaluated as 0.005.

**Needed:** confirm that treating the detection limit as the value, plus a review flag,
is acceptable — or specify per-biomarker handling.

### G11 — Biomarker → nutrient priority floors
`app/nutrition/gaps.py` → `_DEFAULT_FLOORS` (0.75 / 0.60 / 0.30 of the daily target for
critical-low / low / borderline-low)

These are food-ranking weights, never doses, and they never appear in a number shown to
a user. But they do decide how hard the planner pushes iron-rich or B12-rich foods.
The three fractions are engineering judgement.

**Needed:** clinician view on how strongly diet should be steered by a low ferritin,
vitamin D, B12, folate or zinc, and whether any of these links should instead simply
route the user to a doctor.

### G12 — Haemoglobin has two numbers on purpose *(resolved by design — do not "fix")*
`app/rules/red_flags.py` → `HB_CRITICAL_LOW = 7.0`
`db/seed/202_reference_ranges.sql` → `HB … critical_low = 8.0`

They answer different questions and both are kept:

| Number | Question | Effect |
|---|---|---|
| **7.0 g/dL** (docs/04, AABB transfusion trigger) | is this person in immediate danger? | `urgent` card |
| **8.0 g/dL** (WHO 2011 severe anaemia) | how far from normal is this? | `critical_low` classification |

So a haemoglobin of **7.5 g/dL classifies `CRITICAL_LOW` and escalates
`see_doctor_soon`**, not `urgent`. That path is `red_flags.critical_status_flags`, and it
is covered by a test. `db/seed/GAPS.md` section 4 item 1 raised this as a conflict; this
is the settled answer, and the comment above the constant says so.

**Needed:** clinician sign-off on the split. Nothing to change unless they disagree.

### G13 — Two biomarkers this engine uses are not in the seeded catalogue
`app/rules/normalise.py` → `BIOMARKERS`

- **`NEUTROPHILS_ABS`** (absolute neutrophil count, cells/µL). The catalogue seeds
  `NEUT_PCT`, the *percentage*, which the neutropenia red flag cannot use — a
  percentage without a total white count is not an absolute count. The rule is written
  and tested but will never fire until the code exists and labs' absolute counts are
  mapped to it.
- **`ZINC`** (serum zinc, µg/dL). Referenced by the biomarker → nutrient mapping in
  `app/nutrition/gaps.py`, but there is no such biomarker in the catalogue, so a low
  zinc can never reach it.

**Needed:** add both to `db/seed/200_biomarkers.sql` with canonical units and synonyms,
or delete the rules that reference them. Do not leave them half-wired.

### G14 — One nutrient key is spelt two ways
`db/seed/203_rda_targets.sql` stores energy as **`energy_kcal`**; `foods.per_100g`
stores it as **`kcal`**. Gap arithmetic subtracts one from the other, so a mismatch
would silently produce a zero energy gap for every user.

`app/nutrition/targets.py` translates on the way in
(`RDA_NUTRIENT_ALIASES`/`normalise_nutrient_key`) and uses the food spelling
internally, so nothing is broken today.

**Needed:** the two files should agree. Preferably rename the seed row to `kcal` and
delete the alias.
