# The AI pipeline

Your rule — *medical knowledge → trusted sources → rules/validation → LLM reasoning →
safety layer → user* — becomes these eight stages. Stages in **bold** contain no model call
at all.

## Stage 1 — Ingest
File arrives (PDF, JPG, PNG, HEIC). Backend computes a SHA-256 hash. **If we have seen this
exact file before, we reuse the stored extraction and make no model call.** Stored in a
private Supabase bucket; row created in `reports` with `status = 'extracting'`.

## Stage 2 — Extract  *(Gemini 2.5 Flash, multimodal, temperature 0)*
The file bytes go to Gemini with `responseMimeType: application/json` and a strict
`responseSchema`. This is *controlled generation* — the API is structurally prevented from
returning anything but JSON matching our schema, so there is no regex parsing and no
"sometimes it returns markdown" failure mode.

The model is asked to **transcribe, not interpret**:

```json
{ "lab_name": "...", "collected_on": "2026-08-14", "report_type": "blood",
  "rows": [ { "printed_test_name": "Vitamin D (25-OH)", "value_text": "14.2",
              "unit_text": "ng/mL", "printed_range": "30 - 100",
              "method": "CLIA", "confidence": 0.97 } ] }
```

No diagnosis, no advice, no opinion. Just what is on the page.

## Stage 3 — **Normalise** *(deterministic)*
`printed_test_name` → canonical code via a `biomarker_synonyms` table:
`"Vit D (25-OH)"`, `"25-Hydroxy Vitamin D"`, `"25(OH)D"` → `VITD_25OH`.
Units converted to our canonical unit (`ng/mL` ↔ `nmol/L`, `mg/dL` ↔ `mmol/L`).

If a row cannot be mapped confidently, it is stored with `needs_review = true` and **shown
to the user**: *"We found 'S. Ferritin' — is this Ferritin?"* We never silently guess a
health value.

## Stage 4 — **Classify** *(deterministic)*
Compared against **our** `reference_ranges` table, keyed by biomarker, sex, age band and
pregnancy status — not the range printed by the lab (labs differ and print errors happen)
and never the model. Result: `critical_low | low | borderline_low | normal | borderline_high
| high | critical_high`.

## Stage 5 — **Red flags** *(deterministic)*
Hard thresholds produce an escalation level, independent of anything the model says:

| Escalation | Examples |
|---|---|
| `urgent` | Haemoglobin < 7 g/dL · potassium < 2.5 or > 6.0 mmol/L · fasting glucose > 300 mg/dL · platelets < 50,000 |
| `see_doctor_soon` | HbA1c ≥ 6.5% first time · TSH > 10 mIU/L · creatinine rising > 30% vs last report |
| `routine` | Mild single-nutrient deficiency |

Symptom red flags from chat get the same treatment: chest pain, sudden breathlessness,
sudden vision loss, one-sided weakness, blood in vomit or stool, fainting, thoughts of
self-harm → an **undismissable escalation card** with local emergency numbers, shown
*before* any nutrition advice. The model does not decide this; a keyword-and-rule classifier
does, so it cannot be talked out of it.

## Stage 6 — Plan generation  *(Gemini 2.5 Flash, tightly constrained)*
The model receives a compact, fully-assembled context — and critically, **a candidate food
list retrieved from our database**, already filtered by vegetarian/non-vegetarian, allergies,
dislikes, region and season:

```
PROFILE      32 y male · 74 kg · 172 cm · moderately active · Hyderabad
FINDINGS     VITD_25OH low (14.2 ng/mL) · FERRITIN borderline_low · HBA1C normal
GAPS         vitamin D 78% below target · iron 34% below · fibre 40% below
GOALS        1 reduce weight (priority high) · 2 reduce hair fall (high)
LIKES        eggs 5★ · dosa 5★ · ragi 4★ · chicken 5★
DISLIKES     soya chunks 1★ · oats 2★ · bitter gourd 1★
HABITS       skips breakfast on weekdays · dinner ~21:30 · gym Tue/Thu/Sat
CANDIDATES   [312 foods with per-100 g nutrient rows]
```

It composes meals **only from `CANDIDATES`**, returning food IDs and portion sizes — not
food names it invented and not nutrient numbers.

## Stage 7 — **Recompute and validate** *(deterministic)*
1. **Nutrient maths is redone in Python** from the `foods` table. Whatever the model claimed
   is discarded. The "why this food" text the user sees — *"18 g protein, 4.2 g fibre,
   covers 31% of today's iron gap"* — is generated from real numbers.
2. **Safety validator** scans the output for:
   - a drug-name dictionary (generic + Indian brand names),
   - dosage patterns (`\b\d+\s?(mg|mcg|µg|IU|ml|tablets?)\b` near an imperative verb),
   - diagnosis phrasing (`you have`, `you are diabetic`, `this confirms`),
   - advice to stop or change a prescribed treatment.
   A hit means regenerate once with the violation quoted back; a second hit means fall back
   to a safe templated response. Every verdict is logged in `ai_runs`.
3. **Policy judge** (Gemini 2.5 Flash, cheap) runs only on outputs the deterministic scan
   marks ambiguous.
4. Disclaimer and, where relevant, the escalation card are appended. They are not optional
   and are not the model's choice.

## Stage 8 — **Persist and schedule** *(deterministic)*
Plan rows are written; the app pulls them and schedules device-local notifications. Alerts
never require the server to be awake.

---

## Model routing

| Task | Model | Why |
|---|---|---|
| Report extraction | 2.5 Flash | Multimodal, fast, cheap, schema-constrained |
| Chat + follow-up questions | 2.5 Flash | Latency matters in conversation |
| Daily / weekly meal plan | 2.5 Flash | High volume |
| Weekly & monthly review, multi-report trends | **2.5 Pro** | Genuine multi-step reasoning across time |
| Ambiguous safety adjudication | 2.5 Flash | Cheap second opinion |

One file (`backend/app/ai/routing.py`) maps task → model, so switching models is a
one-line change with no app update.

## Staying inside the free tier

- **Never re-extract a file** — content hash cache.
- **One plan generation per day**, not per screen open. Screens read stored plans.
- **Compact chat context**: a rolling summary plus the structured memory block, not the full
  message history.
- **Batch the weekly review** into a single 2.5 Pro call on Sunday night.
- Track every call's tokens and latency in `ai_runs` so cost is visible before it is a
  problem.

## The learning loop

Three layers of preference, all inspectable and editable by the user:

1. **Declared** — onboarding and settings: veg/non-veg, allergies, dislikes, meal times,
   cuisine, budget.
2. **Observed** — `food_logs` and `food_feedback`. A score per food from rating, how often
   eaten, how often skipped, and recency. Pure arithmetic, no model.
3. **Inferred** — the model extracts atomic facts from chat (*"I skip breakfast on
   workdays"*, *"dairy upsets my stomach"*) into `user_memory` with a confidence score and a
   link to the message it came from. **Low-confidence facts are shown to the user to confirm
   or reject before they influence a plan.**

All three compile into the compact preference block above. No vector database is needed at
this size; `pgvector` is available in Supabase if the memory table ever outgrows it.

**Make the learning visible.** When tomorrow's plan changes, the app says why: *"Dropped
soya chunks — you rated it 1★ twice."* An invisible learning system feels broken; a visible
one feels alive. This is the difference between an app someone uses for a week and one they
use for a year.
