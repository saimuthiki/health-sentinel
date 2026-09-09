# HealthPulse — project memory

> This file is loaded automatically at the start of every Claude Code session in this
> repository. It is the durable record of what we are building and the rules that must
> never be broken. Read `docs/00-original-brief.md` for the owner's full brief in their
> own words. **Do not delete or shorten this file.**

## What this is

An **AI health and nutrition coaching app** (Flutter + FastAPI + Gemini). A user uploads
lab reports, scans, prescriptions and food photos. The system extracts the data, checks it
against deterministic medical reference rules, and turns it into a continuously-updated,
personalised plan: meals with nutritional reasoning, hydration, activity, sleep, grocery
lists and timed alerts. It learns the user's food likes, dislikes and habits over time and
folds new symptoms and goals from chat into the next plan.

The loop, not the one-shot analysis, is the product:

    health data -> analysis -> goals -> personalised plan -> daily actions
    -> alerts -> user feedback -> updated preferences -> better next plan

## Safety charter — NON-NEGOTIABLE

The app is a **health and wellness coach**. It is **not** a doctor and must never present
itself as one.

**The app MAY:**
- Explain what a lab value means in plain language.
- Flag values outside reference range as "worth discussing with a doctor".
- Suggest foods, meals, hydration, sleep, activity and ordinary home/kitchen remedies.
- Track goals, meals, habits and progress; build grocery lists.
- Explain *why* a food helps (fibre, iron, B12 content) using our nutrition database.
- Send reminders and nudges.
- Tell the user which questions to ask their doctor, and when to see one.

**The app MUST NOT:**
- Prescribe, name, recommend, or change any **medication** or **dosage** — including
  supplement doses (e.g. "take 60,000 IU vitamin D weekly" is a prescription; "vitamin D is
  low — sunlight and these foods help, and ask your doctor whether you need a supplement"
  is coaching).
- State a **diagnosis** ("you have diabetes"). It says "this pattern is often associated
  with X — please confirm with a doctor".
- Tell a user to stop, skip or delay any prescribed treatment.
- Downplay a red-flag symptom or an out-of-range critical value.

Enforcement is in **three independent places** and all three must stay in place:
1. System prompt / persona (`backend/ai/prompts/`).
2. Deterministic post-generation validator (`backend/safety/`) — drug dictionary, dosage
   regex, diagnosis phrasing. Runs on every model output before it reaches the user.
3. UI — permanent disclaimer, and escalation cards that cannot be dismissed for
   `urgent` findings.

The LLM is a **reasoning and language interface**, never the medical source of truth.
Reference ranges, abnormality classification, red-flag thresholds and nutrient values are
**deterministic code and curated data**, not model output.

## Hard technical rules

- **No secret ever enters this repository or the mobile app.** The Gemini API key lives
  only in backend environment variables. The app talks to our backend; the backend talks to
  Gemini. An API key shipped inside an APK can be extracted by anyone.
- **Every table is scoped by `user_id` and protected by Postgres Row Level Security.**
  Isolation is enforced by the database, not by application code.
- **Nutrient numbers shown to the user come from the `foods` table**, never from model
  free-text. The backend recomputes totals and overwrites anything the model claimed.
- **Never silently guess a lab value or unit.** Unmappable values are marked
  `needs_review` and shown to the user for confirmation.
- **"Delete all my health data" must actually delete it**, including files in storage.

## Owner / working agreement

- Owner: Sai Muthiki. New to app development — explanations should be in plain, simple
  English, step by step.
- The owner performs all account creation and secret entry themselves. **Never ask the
  owner to paste a secret into chat.**
- Budget: free tiers wherever possible. Flag honestly when a free tier will not do the job.
- Anything that cannot be done from a Claude session (creating accounts, paying, phone
  settings, Play Console) must be listed explicitly in `docs/06-manual-steps.md`.

## Where things live

    app/        Flutter mobile app (Android first, iOS later)
    backend/    FastAPI service: API, rules engine, AI orchestration, safety layer
    db/         SQL migrations, RLS policies, seed data (biomarkers, foods, RDAs)
    docs/       Product, architecture, data model, AI pipeline, roadmap, manual steps
    .github/    CI: tests, lint, Android build

Start with `docs/README.md`.
