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

### G15 — The water target is EFSA's, not ICMR-NIN's, and does not move with weight, heat or training
`app/rules/daily_goals.py` → `TOTAL_WATER_ML`, `DRINKS_SHARE_OF_TOTAL_WATER`,
`HYDRATION_FLOOR_ML`

Every other target in this project cites ICMR-NIN 2020. This one does not, because an
ICMR-NIN figure for water intake could not be stated with confidence, and the rule here
is cite or omit. What ships instead is EFSA's adequate intake of **total** water for
adults — 2.5 L/day for men, 2.0 L/day for women — times the 80% EFSA attributes to
drinks rather than to food. So the goal varies by **sex only**.

Three things it deliberately does *not* do, each because we hold no citable figure:

- **Body weight.** EFSA states the intake per adult, not per kilogram. The familiar
  30–35 mL/kg/day clinical rule of thumb is real but we could not attribute it to a
  specific guideline with confidence, so an 82 kg man and a 60 kg man currently get the
  same 2000 mL.
- **Physical activity.** EFSA scopes its figure to *moderate* activity and says needs
  rise above it, without giving an amount. Someone playing badminton daily gets no
  uplift from us.
- **Climate.** Same: EFSA scopes the figure to *moderate ambient temperature*. A
  Hyderabad summer gets no uplift either.

The 80% share is the one judgement in the rule: EFSA gives a 70–80% range for drinks
and we take the top of it, so that a drinking goal is never set below what the source
supports. That choice is written into the constant rather than folded into a number.

**Needed:** the ICMR-NIN 2020 water figure read off the printed table, and a sourced
uplift for heat and for exercise — ideally one a dietitian will put their name to. Until
then the number is defensible but blunt, and the app should not imply it was tailored
more finely than it was.

### G16 — The movement target is a weekly guideline shown as a daily bar
`app/rules/daily_goals.py` → `WEEKLY_FLOOR_MINUTES`, `WEEKLY_UPPER_MINUTES`,
`HIGHER_TARGET_ACTIVITY_LEVELS`

WHO 2020 states 150–300 minutes of moderate-intensity aerobic activity **per week** for
adults. There is no daily figure in the guideline. The API returns the weekly number as
the real target and a daily one derived from it (weekly ÷ 7, rounded up), which is a
display convenience and nothing more.

Two gaps sit underneath it:

- **Who gets 300 rather than 150** is our call, not WHO's. We give the upper end of the
  range to a profile that already records `active` or `very_active`, on the grounds that
  WHO names the upper half as where additional benefit is gained. Nothing in the
  guideline says to allocate it that way.
- **Under-18s get no target.** WHO's recommendation for 5–17 year olds is a different
  shape (a daily average, not a weekly total) and we have not curated it, so
  `resolve_movement_target()` returns `None` below 18. Same stance as G6.

WHO's muscle-strengthening recommendation (2+ days a week) is not modelled at all.

**Needed:** a decision on how the 150–300 range should be allocated, and the 5–17 band
if the product ever stops being adults-only.

### G17 — Every MET value in the activity list is unchecked against the printed Compendium
`app/rules/activity_energy.py` → `ACTIVITIES`

The energy figure the app now shows ("about 290 kcal for 45 minutes of badminton") is
`MET × body weight in kg × hours`. The MET values come from the 2011 Compendium of
Physical Activities (Ainsworth et al., *Med Sci Sports Exerc* 2011;43(8):1575–1581),
and each row in `ACTIVITIES` carries the Compendium's own activity code and its own
wording of the activity so that any of them can be looked up in one step.

**They were written from recall of that source, not read off it.** Network access to the
Compendium was blocked in the session that added them, and none of the eleven has been
compared with the published table. So each value is a citation of a real published
number that has not been verified here — which is a different and weaker claim than
every other cited number in this engine makes, and it is the reason this item exists
rather than the values simply shipping.

The ten to check, with what the code currently claims:

| Key | Code | MET | Compendium wording as stored |
|---|---|---|---|
| `badminton` | 15030 | 5.5 | badminton, social singles and doubles, general |
| `running` | 12050 | 9.8 | running, 6 mph (10 min/mile) |
| `walking` | 17190 | 3.5 | walking, 3.0 mph, level, moderate pace, firm surface |
| `cycling` | 01040 | 8.0 | bicycling, 12–13.9 mph, leisure, moderate effort |
| `gym_strength` | 02054 | 3.5 | resistance (weight) training, multiple exercises, 8–15 repetitions |
| `yoga` | 02150 | 2.5 | yoga, Hatha |
| `swimming` | 18240 | 5.8 | swimming laps, freestyle, front crawl, slow, moderate or light effort |
| `cricket` | 15200 | 4.8 | cricket, batting, bowling, fielding |
| `stairs` | 17133 | 4.0 | stair climbing, slow pace |
| `housework` | 05040 | 3.3 | cleaning, sweeping carpet or floors, general |

One of these carries more weight than the others: `yoga` at 2.5 METs is **below** the
3.0 MET line, which is why `counts_toward_target` is false for it and an hour of yoga
does not move the WHO bar. If the real figure is 3.0 or above, that behaviour is wrong,
not just the number.

**Needed:** each row checked against the printed 2011 Compendium and corrected or
confirmed. Until that is done the list is defensible — every figure names a real source
and can be traced — but it is not verified, and nothing in the tests can make it so.

### G18 — A MET figure is a population average, and the formula is gross not net
`app/rules/activity_energy.py` → `energy_kcal`, `ENERGY_IS_AN_ESTIMATE`

Two limits are built into this arithmetic and neither can be removed by better data
entry. Both are stated to the user in `ENERGY_IS_AN_ESTIMATE`, which the API sends
alongside every figure so the number cannot be shown without them.

- **It is not a measurement of this person.** A MET value is the average energy cost of
  an activity measured on a group of other people. Fitness, technique, effort, terrain,
  heat and body composition all move the real figure and none of them is an input here.
  Two people of the same weight playing the same hour of badminton do not spend the same
  energy. The app must therefore never present this as an observation — "about 290 kcal,
  an estimate" is honest, "you burned 290 kcal" is not.
- **It is gross, not net.** `MET × kg × hours` is the *total* energy used during the
  session, which includes the roughly 1 MET the body would have spent lying still for the
  same minutes. The extra energy attributable to the exercise is nearer
  `(MET − 1) × kg × hours` — for a one-hour 3.5 MET walk that is a 29% difference. Gross
  is what the Compendium's own formula gives and what comparable apps show, so it is what
  ships, with the inclusion said out loud rather than glossed.

A third, smaller one: the MET is defined against 3.5 mL O₂/kg/min, a figure derived from
a reference adult. It is known to overestimate for people well above that reference
weight and underestimate below it. No correction is applied because we hold no citable
one.

**Needed:** a decision, ideally from a dietitian, on whether the app should show net
rather than gross energy, and a sourced correction for the reference-weight bias if one
exists. Neither is a bug in the current arithmetic; both change what the number means.

### G19 — "Calories burnt till date" is bounded by the audit trail's row limit
`app/api/activity.py` → `TRAIL_ROW_LIMIT`, `ActivityTotalsOut.truncated`

The lifetime total is folded from `health_events`, which is read through
`AuditRepository.events_since`. That method takes a row limit (500) and orders
**ascending**, so a user with more than 500 logged sessions of one event type would have
their *newest* sessions dropped from the read — the opposite of what anybody would
expect, and it would silently make today's figures wrong as well.

What the code does about it today: the lifetime read reports `truncated: true` when it
comes back full, so the app says "at least" rather than a flat total, and today and this
week are re-read over a 31-day window in that case so those two stay exact. Nothing is
under-reported without saying so.

What it does not do is fix the underlying limit, because that needs either a paging read
or an aggregate on `health_events`, and `app/repositories/` was not this change's to
edit. At one session a day, 500 rows is about sixteen months.

**Needed:** a paged or aggregating read on `AuditRepository` — or, better, the movement
table that `app/api/feedback.py` notes does not exist — so that "till date" needs no
asterisk.

### G20 — A water goal the user sets for themselves, and the two numbers that fence it in
`app/rules/daily_goals.py` → `HYDRATION_CAUTION_ABOVE_ML`, `HYDRATION_CEILING_ML`,
`HYDRATION_OVERRIDE_FLOOR_ML`, `judge_hydration_choice()`

The owner asked to set his own water goal, and named **5 litres a day**. He trains hard,
daily, in Hyderabad. That is the exact profile in which exercise-associated hyponatraemia
happens: sustained high intake, heavy sweating, and a fixed target drunk to regardless of
thirst. It has killed athletes.

Refusing him outright is not the product's call to make about his own body, and quietly
capping him at a number he did not choose is worse — he would believe he was drinking 5 L
while the bar measured something else. So `resolve_hydration_target()` now takes an
optional `hydration_target_override_ml` off the profile and uses it, with the sourced
figure carried alongside it in `sourced_millilitres` and named in `source`, so the
evidence is always on screen next to the choice.

Three numbers were needed, and only one of them has a guideline behind it:

- **Warn above 3000 mL** (`HYDRATION_CAUTION_ABOVE_ML`). The highest adult adequate
  intake for *total* water in the sources we hold is IOM 2005's 3.7 L/day for men, and
  IOM attributes 75–84% of total water to drinks — a beverage share of roughly 2.8–3.1 L.
  3000 mL is the round figure just inside the top of that band, so the warning begins
  slightly before the published range runs out. Above it the app says, in plain words,
  that too much water dilutes the salt in the blood, that the risk is higher when
  sweating heavily, and that it is worth asking a doctor. It **warns**; it does not
  block, cap or round.
  *Citations:* Institute of Medicine (US) Panel on Dietary Reference Intakes for
  Electrolytes and Water. *Dietary Reference Intakes for Water, Potassium, Sodium,
  Chloride, and Sulfate.* Washington, DC: The National Academies Press; 2005. —
  Hew-Butler T, Rosner MH, Fowkes-Godek S, et al. Statement of the Third International
  Exercise-Associated Hyponatremia Consensus Development Conference, Carlsbad,
  California, 2015. *Clin J Sport Med.* 2015;25(4):303–320.

- **Refuse above 6000 mL** (`HYDRATION_CEILING_ML`). **This figure is ours, not a
  guideline's, and that is the gap.** No body publishes a daily maximum for water: IOM
  2005 deliberately set *no* Tolerable Upper Intake Level, on the grounds that healthy
  kidneys excrete the excess. The one hard number in the literature is the rate, not the
  daily total: Noakes et al. measured peak urine flow of about 735–970 mL/hour in healthy
  adults during oral fluid overload and concluded that intake much faster than that
  cannot be cleared. 6000 mL spread over the 16 waking hours this app schedules reminders
  in is 375 mL/hour — about **half** the slowest of those measured peaks. Half rather than
  the rate itself, because a peak diuresis measured under maximal stimulation is not a
  rate anyone sustains for a day, and because dilutional hyponatraemia occurs well below
  maximal renal clearance once exercise and heat are stimulating ADH. It is the most
  generous ceiling we are prepared to defend out loud, not a safe amount.
  *Citation:* Noakes TD, Wilson G, Gray DA, Lambert MI, Dennis SC. Peak rates of diuresis
  in healthy humans during oral fluid overload. *S Afr Med J.* 2001;91(10):852–857.

- **Refuse below 500 mL** (`HYDRATION_OVERRIDE_FLOOR_ML`). Not clinical at all, and
  labelled as such in the code and in the refusal text: it is the point below which a
  daily goal stops being a goal.

Two interactions were decided here rather than left to whoever reads this next:

- **A profile we hold no water figure for** — pregnancy, a fluid-restricting condition,
  under 18 — cannot set a goal above 3000 mL at all: `judge_hydration_choice()` refuses
  it and the refusal carries the existing "ask your doctor" text. A smaller figure is
  stored but never shown, and the person is told it is not being shown. The reason for
  refusing rather than warning is that a stored high goal on a restricted profile becomes
  live the day the condition is edited off the profile, which is a hazard with a delay
  on it. The existing behaviour is otherwise untouched: those profiles still get **no**
  target and a reason, never a default and never a number they typed.
- **A goal already stored that is outside the envelope** — written by any path, including
  one this module does not own — is ignored on read in favour of the sourced figure, with
  the reason appended to `source`. The check runs on the way out as well as on the way in.

Every choice and every warning shown is also written to the audit trail by
`app/api/plan.py` (`hydration_target_set` with the millilitres, the sourced figure and
the exact caution text; `hydration_target_refused` with what was asked for and why it was
refused), so a clinician can review what a person set and what they were told.

**Needed:** a clinician to confirm or replace the 3000 mL warning threshold and — much
more importantly — the 6000 mL ceiling, which is a construction of ours from a measured
hourly rate and not a published daily limit. Also worth deciding: whether a profile that
records daily hard training in a hot climate should warn *earlier* than 3000 mL rather
than later, since that is the population in which the harm is documented.

---

### G21 — The weekly summary counts taps, not eating, and cannot count water at all
`app/rules/weekly_rollup.py` → `roll_up()`, `factual_lines()`

The weekly summary is built entirely from counts this service can prove from its own
rows. Three of those counts are further from the thing a reader will assume they mean
than we would like, and the copy hedges each one rather than pretending otherwise.

- **"Marked eaten" is a tap, not a meal.** `plan_item_progress` records that somebody
  pressed a button on a plan item. Whether the food was eaten, how much of it, and
  whether it was eaten that day are all unrecorded. The sentences therefore say *marked*,
  never *ate*, and the day attributed to a mark is the day of the tap (`occurred_at`),
  because the payload carries no date of its own. Somebody who catches up on Sunday
  evening will see one active day, not five, and that is the honest reading of what we
  hold.
- **Water is not counted at all.** There is no endpoint to log a glass of water against:
  `logHydration` in `app/lib/data/repository/http_health_repository.dart` writes to the
  phone's own offline cache and nothing sends it anywhere. The only hydration figure the
  backend holds is what a *plan asked for*, which is not what anybody drank. The summary
  says so in `NOT_MEASURED` rather than quietly reporting the plan's figure as intake.
  **Needed to close this:** a `POST /v1/feedback/hydration` writing to `health_events`
  the way movement already does, after which `roll_up()` gains a fourth fold and one more
  sentence. Until then any "you drank more this week" line is a fabrication and is
  forbidden by `app/rules/summary_prose_rails.py`.
- **A quiet week is defined by two constants nobody has validated.**
  `MIN_SIGNALS_FOR_PROSE = 2` and `MIN_ACTIVE_DAYS_FOR_PROSE = 2` are the point below
  which the summary refuses to say anything encouraging. They are a judgement about
  honesty, not about health, and they are deliberately generous towards silence: an empty
  week reported as empty is what makes a full week's sentence believable. Worth revisiting
  once there is real usage, because a threshold that is too high tells a person who is
  genuinely starting out that they did nothing.

**Needed:** nothing clinical. This item is here so that whoever reads a summary knows
exactly which claim each number can carry, and so that the hydration gap is closed
deliberately rather than by somebody wiring the plan's figure into it.

---

### G22 — A recipe is a method with no amounts in it, and the plan's arithmetic is why
`app/rules/recipe_text_rails.py` → `check_recipe_text()`

A plan item is one food from the `foods` table at a weight in grams, and its nutrition is
recomputed from that single row. A generated method that says "two tablespoons of ghee"
has silently changed the meal, and the Plan tab's numbers would then be describing a dish
nobody is going to cook. The planner never populates `recipe_id`
(`app/planner/service.py` → `parse_plan_items`), so there is no `recipe_items` row to
recompute from, and asking a model for ingredient weights would put nutrient numbers back
into model output.

So generated recipes carry **no unit of mass or volume at all** — no grams, no
millilitres, no cups, no spoons — and the only quantity on the recipe screen is the plan
item's own `grams`, printed in Python from the stored row. The rail is mechanical and
tested; the honest description of the result is that HealthPulse gives you a *method*, and
the amounts stay the plan's.

Two known costs of that choice, recorded rather than hidden:

- **The method is less useful than a real recipe.** "Enough water to cover" is a real
  instruction; "one and a half cups" is a better one. A cook who wants exact amounts has
  to bring their own.
- **Aromatics, oil and salt are outside the plan's numbers whatever we do.** Nobody eats
  rajma without oil, and the plan's energy figure for the item does not include any. The
  recipe screen does not pretend otherwise, but neither does it correct for it.

**Needed:** if the owner ever wants amounts in a recipe, the honest way to get them is a
curated `recipes` + `recipe_items` seed — real ingredient rows joined to `foods`, from
which `recompute_plan_items()` can compute nutrition the same way it does for a single
food. That is a data problem, not a prompting problem, and it is already noted as item 6
in `db/seed/GAPS.md`. Generating the amounts would not close it.
