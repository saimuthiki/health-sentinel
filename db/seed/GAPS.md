# GAPS — what is deliberately missing from the seed data

**Who this file is for:** a clinician, pathologist or registered dietitian who can
supply the numbers we would not invent, and the engineer who loads them.

**Why it exists.** `CLAUDE.md` says the app must never guess a health number, and
the brief for this database said it plainly: *never invent a medical reference
threshold — cite or omit*. So every threshold in `202_reference_ranges.sql` and
every target in `203_rda_targets.sql` carries a `source_citation` naming the
guideline it came from, and **anything that could not be sourced with confidence
was left out rather than estimated**.

That is why this file is long. A long gap list is the honest outcome; a short one
would have meant we started making numbers up.

**What a gap means at runtime.** A missing threshold is *not* "normal". The
classifier must return `needs_review` / "cannot classify" for a direction it has
no threshold for, and the app must not tell the user a value is fine because we
had nothing to compare it with. Please make sure the backend behaves that way
before any of these gaps are filled.

---

## 1. What IS seeded

| File | Rows | Coverage |
|---|---|---|
| `200_biomarkers.sql` | 82 biomarkers | CBC, lipid, thyroid, liver, kidney, glycaemic, vitamins, iron studies, minerals, electrolytes, and common extras |
| `201_biomarker_synonyms.sql` | 353 synonyms | Printed lab names → canonical codes |
| `202_reference_ranges.sql` | **28 ranges over 21 biomarkers** | Every row cited |
| `203_rda_targets.sql` | 16 targets over 8 nutrients | ICMR-NIN 2020, Indian adults 19–59 |
| `204_foods_starter.sql` | 147 foods | Indian staples, all marked `PROVISIONAL` |

---

## 2. Reference ranges — biomarkers with NO range at all (61 of 82)

These 82 − 21 = **61 biomarkers can be recognised and stored, but not
classified.** They need a clinician to supply low / high / critical values *with
a citation*, ideally the interval the reporting laboratory itself validated.

**Haematology (14)** — `RBC`, `WBC`, `PCV`, `MCV`, `MCH`, `MCHC`, `RDW`,
`NEUT_PCT`, `LYMPH_PCT`, `MONO_PCT`, `EOS_PCT`, `BASO_PCT`, `ESR`, `RETIC_PCT`

> Note on ESR: the age- and sex-dependent rule of thumb (men `age/2`, women
> `(age+10)/2`, Miller et al., *BMJ* 1983) is a formula, not a band, so it does
> not fit the table as it stands. Decide whether to encode it as age bands or as
> code in the rules engine.

**Liver (10)** — `BILI_TOTAL`, `BILI_DIRECT`, `BILI_INDIRECT`, `AST`, `ALP`,
`GGT`, `PROTEIN_TOTAL`, `ALBUMIN`, `GLOBULIN`, `AG_RATIO`

> `ALT` **is** seeded (ACG 2017). `AST` is not: the same guideline does not give
> an equivalent sex-specific healthy upper limit, and the two must not be assumed
> to share one.

**Kidney (4)** — `UREA`, `BUN`, `CREATININE`, `UACR`

> Serum creatinine intervals depend on assay calibration and on muscle mass, and
> published Indian intervals differ from Western ones. `EGFR` is seeded (KDIGO
> 2012) and is the safer thing to classify on. For `UACR`, the KDIGO albuminuria
> categories (A1 <30, A2 30–300, A3 >300 mg/g) are the obvious source — confirm
> and add.

**Thyroid (5)** — `FT3`, `FT4`, `T3_TOTAL`, `T4_TOTAL`, `ANTI_TPO`

> Free T3/T4 and antibody intervals are strongly assay-dependent. Take them from
> the assay insert of whichever platform the user's lab runs, or leave unclassified.

**Minerals and electrolytes (7)** — `SODIUM`, `CHLORIDE`, `BICARBONATE`,
`CALCIUM`, `CALCIUM_IONIZED`, `PHOSPHORUS`, `MAGNESIUM`

> `POTASSIUM` has **critical values only** (see section 3). The familiar printed
> intervals (e.g. potassium 3.5–5.1, sodium 135–145, calcium 8.5–10.5 mg/dL) are
> method-dependent and could not be attributed to a specific guideline with
> confidence, so they were left out. Critical values for sodium and calcium are a
> priority — a sodium of 118 mmol/L is an emergency and the app currently has
> nothing to escalate on.

**Iron studies (4)** — `IRON`, `TIBC`, `UIBC`, `TRANSFERRIN_SAT`

> `FERRITIN` is seeded (WHO 2020 + BSG 2021). Transferrin saturation <20% (or
> <15% in some sources) is widely used for iron deficiency — pick one source and
> cite it.

**Lipid (5)** — `VLDL`, `CHOL_HDL_RATIO`, `LDL_HDL_RATIO`, `LIPOPROTEIN_A`, `APO_B`

**Hormones (4)** — `CORTISOL_AM`, `PTH`, `TESTOSTERONE_TOTAL`, `PROLACTIN`

**Others (8)** — `INSULIN_FASTING`, `HOMOCYSTEINE`, `LDH`, `CPK`, `AMYLASE`,
`LIPASE`, `PSA`, `VITA`

> Homocysteine >15 µmol/L is a commonly quoted cut-off but we could not tie it to
> a single authoritative guideline, so it was omitted rather than guessed.
> Fasting insulin and HOMA-IR have no accepted diagnostic cut-off at all.

---

## 3. Reference ranges — rows that are deliberately incomplete

These rows **are** seeded, but with holes. Each hole is a separate decision to
document rather than fill.

| Biomarker | What is missing | Why |
|---|---|---|
| `HB` (all bands) | upper limit | WHO 2011 defines anaemia only. Polycythaemia thresholds come from a different source. |
| `PLT` | normal interval | Only the red-flag `critical_low = 50` is seeded (docs/04 + CTCAE v5.0 grade 3). The familiar 150–450 ×10³/µL is laboratory-specific. |
| `POTASSIUM` | normal interval | Only `critical_low 2.5` / `critical_high 6.0` from docs/04 stage 5. |
| `VITD_25OH` | upper limit | No confidently sourced toxicity threshold. Also see the standards conflict below. |
| `VITB12`, `FOLATE`, `FERRITIN` | upper limits | Deficiency thresholds are what the guidelines define; "too high" is a different clinical question. |
| `TSH` | critical values | ATA/AACE define subclinical and overt bands, not critical values. |
| `ALT` | lower limit, critical high | ACG 2017 gives an upper limit of normal only. |
| `EGFR` | upper limit | Not clinically meaningful. |
| `HBA1C`, `GLUCOSE_PP`, `GLUCOSE_RANDOM` | low / critical values | ADA defines the diabetes thresholds; hypoglycaemia is defined on plasma glucose, which is seeded on `GLUCOSE_FASTING`. |
| `CHOL_TOTAL`, `LDL`, `TRIG`, `NON_HDL`, `HDL`, `CRP_HS`, `URIC_ACID` | low side | Not a defined abnormality in the cited guidelines. |

---

## 4. Conflicts a clinician must settle

1. **Haemoglobin: 7 vs 8 g/dL.**
   `docs/04-ai-pipeline.md` stage 5 escalates adult Hb **< 7 g/dL** as `urgent`.
   WHO 2011 calls **< 8 g/dL** severe anaemia, and that is what is seeded as
   `critical_low` for adults. So a value of 7.5 g/dL classifies as
   `critical_low` but does **not** trigger the urgent card. Decide which number
   governs each behaviour and make the code and this table agree.

2. **Vitamin D: Endocrine Society vs Institute of Medicine.**
   Seeded: Endocrine Society 2011 — deficiency <20, insufficiency 20–29,
   sufficiency ≥30 ng/mL. This is what most Indian labs print.
   The US Institute of Medicine (2011) says ≥20 ng/mL is already sufficient for
   bone health. Under IOM, a large number of users flagged "insufficient" by our
   table are simply normal. Pick one, say which in the app, and cite it.

3. **Non-HDL cholesterol is risk-stratified.**
   Seeded at borderline 130 / high 160 mg/dL (ATP III, LDL goal + 30). The real
   target depends on the individual's cardiovascular risk category. For a
   high-risk user these numbers are too lenient.

4. **Uric acid is seeded sex-neutrally** at borderline 6.0 / high 6.8 mg/dL
   (ACR 2020 target and the urate solubility limit). Many Indian labs print
   sex-specific intervals (roughly 3.5–7.2 male, 2.6–6.0 female). Decide whether
   to keep one row or split it, and cite whichever you choose.

5. **Age bands.** Every adult range is seeded as 18–120 (or 19–59 for the RDAs).
   No paediatric or adolescent lab ranges are seeded at all except the WHO
   haemoglobin bands. **If the app is opened to under-18s, almost nothing will
   classify correctly.** Either restrict the app to adults or commission
   paediatric ranges.

6. **Pregnancy.** Only haemoglobin has a pregnancy-specific row. Thyroid
   (trimester-specific TSH), ferritin, glucose (GDM criteria) and several others
   all change in pregnancy. Until those rows exist, a pregnant user is being
   classified against non-pregnant thresholds for everything except Hb.

---

## 5. RDA targets — what is missing (`203_rda_targets.sql`)

Seeded from ICMR-NIN 2020: energy (by sex × 3 activity levels), protein, calcium,
iron, zinc, vitamin D, vitamin B12, folate — **adults 19–59 only**.

Not seeded, needs to be read off the printed ICMR-NIN 2020 table:

- **Dietary fibre** — a target the app will want constantly (the planner's GAPS
  block references fibre). Not seeded because the ICMR-NIN figure could not be
  stated confidently.
- **Vitamin A, vitamin C, magnesium, iodine, selenium, thiamine, riboflavin,
  niacin, vitamin B6** — all in the ICMR-NIN table, none confidently recalled.
- **Sodium and potassium** upper/adequate intakes.
- **Pregnancy and lactation increments** — ICMR-NIN gives added requirements per
  trimester and for lactation. Nothing is seeded, so a pregnant user currently
  gets non-pregnant targets.
- **Adults 60+** — no rows exist, so the lookup returns nothing for an older
  user. Decide whether to extend the adult band or add a separate one.
- **Children and adolescents (0–18)** — nothing seeded.
- **Activity level `heavy` for non-energy nutrients** — currently `any`, which is
  correct for ICMR-NIN, but confirm.

**Also decide:** ICMR-NIN targets are for the *reference* 65 kg man / 55 kg woman.
For a 95 kg or a 45 kg user, protein at 0.83 g/kg should probably be computed
from their actual weight rather than read from the table. That is a backend
decision; the table stores the reference figure.

---

## 6. Foods — every row is `PROVISIONAL` (`204_foods_starter.sql`)

All **147** rows load with `source = 'PROVISIONAL'` and a `source_id` that is a
readable slug (`ragi`, `toor_dal`, `paneer`), **not** an IFCT 2017 or USDA record
number.

**This is the single biggest thing to fix before real users see numbers.**
`CLAUDE.md` says nutrient numbers shown to the user come from the `foods` table.
Right now that table holds typical published composition figures that have not
been checked row by row against an authoritative source, and marking them
`IFCT2017` would be claiming a provenance we do not have.

**What to do:** run a verified import from IFCT 2017 (ICMR-NIN, *Indian Food
Composition Tables*) for Indian foods and USDA FoodData Central for the rest,
then update each row to the real `source` and `source_id`. The unique index is on
`(source, source_id)`, so a verified row inserts cleanly alongside the
provisional one; delete the provisional row once the app points at the new id.

Specific things to check during that import:

- **Missing micronutrients are missing on purpose.** A key absent from `per_100g`
  means "unknown", not zero. The backend must not total an absent key as 0. Most
  foods carry only kcal / protein / fat / carb / fibre.
- **Amla (Indian gooseberry) vitamin C** is deliberately absent. Indian sources
  quote ~600 mg/100 g and USDA quotes ~28 mg/100 g for gooseberry — an order of
  magnitude apart, almost certainly a different fruit. Do not fill this in
  without checking which one IFCT means.
- **Raw vs cooked.** Every row is raw/dry weight unless the name says otherwise
  (dal, rice, millets are all dry). A user logging "1 katori dal" is eating
  cooked dal at roughly a third of the dry density. The portion logic has to
  handle this or every dal entry will be over-counted by 3×.
- **No prepared dishes.** Idli, dosa, sambar, upma, khichdi, biryani and so on
  are absent by design — they are compositions and belong in `recipes` +
  `recipe_items`, computed from foods. The `recipes` table is currently **empty**.
- **Regional names** (`name_local`) are a small mixed set of Hindi/Telugu/Tamil
  transliterations for recognisability, not a complete localisation.
- **Allergen lists are conservative but not exhaustive.** They cover milk, egg,
  peanut, tree nut, sesame, soy, fish, shellfish, gluten and mustard. Cross-
  contamination is not modelled at all — e.g. oats are not flagged `gluten_free`
  for that reason, but nothing else is.
- **`jain` flag** excludes root vegetables, onion, garlic, ginger and honey. Jain
  dietary practice varies; confirm with the users you have.

---

## 7. Synonyms — the honest caveat (`201_biomarker_synonyms.sql`)

The 353 synonyms use `source = 'common'` or `source = 'indian_lab'`, **not** the
name of a specific laboratory. Writing `source = 'thyrocare'` next to a string
would be claiming we had checked a Thyrocare report and found that exact wording,
and we have not. The column is ready for it: as real reports come in through the
`needs_review` queue, add the exact printed strings with the real lab name.

Two related things to build:

1. **The review queue is the source of new synonyms.** Every row stored with
   `needs_review = true` is a name we could not map. Mine that queue weekly and
   add confirmed mappings here.
2. **Unit conversion is not in this database.** `ng/mL ↔ nmol/L`,
   `mg/dL ↔ mmol/L` and so on live in the backend (pipeline stage 3). The
   thresholds here are all in `biomarkers.canonical_unit`; conversion must happen
   before comparison.

---

## 8. Schema decisions worth a second opinion

Small deviations from `docs/03-data-model.md`, all deliberate, all listed here so
nobody finds them by surprise:

1. **`health_profiles.pregnancy`** was added. `reference_ranges` is keyed by
   pregnancy status, so the profile has to be able to answer the question.
2. **`rda_targets.source_citation`** was added alongside `source`, so every RDA
   row carries a full reference and not just the string `ICMR-NIN 2020`.
3. **`foods.source` allows `'PROVISIONAL'`** in addition to `IFCT2017` and
   `USDA`, for the reason in section 6. Remove that third value from the CHECK
   constraint once the verified import is done.
4. **`health_events` and `ai_runs` are append-only** — RLS gives users SELECT and
   INSERT but no UPDATE or DELETE, so an audit row cannot be rewritten from the
   app. `consents` and `deletion_requests` are the same, for the same reason:
   a receipt a user can edit is not a receipt. Account deletion runs as the
   service role, which bypasses RLS, so "delete all my health data" still works.
5. **`deletion_requests.user_id` is `ON DELETE SET NULL`**, not cascade — the
   receipt has to outlive the account it describes.
6. **`lab_results.report_id` is `ON DELETE SET NULL`** — report files expire after
   90 days but the structured values are the trend history and must survive.
