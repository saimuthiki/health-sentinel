# HealthPulse

**An AI health and nutrition coach — not a doctor.**

Upload your lab reports, scans and prescriptions. HealthPulse extracts the values, checks
them against real medical reference ranges, and turns them into a plan you can act on today:
what to eat and *why*, how much water, when to sleep, what to buy at the weekend. It learns
what you actually eat and enjoy, folds in new symptoms and goals from chat, and tells you
plainly when something needs a doctor.

```
health data → analysis → goals → personalised plan → daily actions
   → alerts → your feedback → updated preferences → better next plan
                └──────────────── repeats forever ────────────────┘
```

## Status

**Planning complete. Implementation starting.** See [`docs/05-roadmap.md`](docs/05-roadmap.md).

## What it is not

It does not diagnose disease, and it never prescribes or doses medication — including
supplements. It explains, coaches, reminds, and tells you what to ask your doctor. The
boundary is enforced in three independent places, described in
[`docs/01-product-and-safety.md`](docs/01-product-and-safety.md).

## Stack

| Layer | Choice |
|---|---|
| Mobile | Flutter (Android first, iOS-clean) |
| Backend | Python · FastAPI |
| Database, auth, storage | Supabase (Postgres + Row Level Security) |
| AI | Google Gemini 2.5 Flash · 2.5 Pro for long-horizon reasoning |
| Alerts | Device-local notifications (Android `AlarmManager`) |
| CI/CD | GitHub Actions |

The AI is a **reasoning and language interface, never the medical source of truth**.
Reference ranges, abnormality classification, red-flag thresholds and every nutrient number
come from curated data and deterministic code. See [`docs/04-ai-pipeline.md`](docs/04-ai-pipeline.md).

## Layout

```
app/        Flutter application
backend/    FastAPI service — API, rules engine, AI orchestration, safety layer
db/         SQL migrations, RLS policies, seed data
docs/       Product, architecture, data model, AI pipeline, roadmap, manual steps
```

## Start here

- New to the project? → [`docs/README.md`](docs/README.md)
- Setting up accounts and tools? → [`docs/06-your-manual-steps.md`](docs/06-your-manual-steps.md)
- Waiting on you? → [`docs/07-open-decisions.md`](docs/07-open-decisions.md)

## Security

No secret ever enters this repository or the mobile app. The Gemini key and the Supabase
service-role key live only in backend environment variables. See `.env.example` for the
variable names.
