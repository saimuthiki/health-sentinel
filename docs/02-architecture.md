# Architecture

## 1. The shape of the system

```
┌───────────────────────────────────────────────────────────────┐
│  Flutter app (Android first, iOS later)                       │
│  Chat · Upload · Dashboard · Plan · Grocery · Trends           │
│  Local SQLite cache  +  device-scheduled notifications         │
└───────────────────────┬───────────────────────────────────────┘
                        │  HTTPS + Supabase JWT
┌───────────────────────▼───────────────────────────────────────┐
│  FastAPI backend  (the only place that holds secrets)          │
│                                                                │
│   api/       REST endpoints, auth verification                 │
│   ingest/    file -> text/structured extraction                │
│   rules/     reference ranges, red flags, RDA gaps  ← NO LLM    │
│   nutrition/ foods, recipes, nutrient maths         ← NO LLM    │
│   ai/        Gemini orchestration, prompts, schemas            │
│   safety/    output validator, escalation            ← NO LLM*  │
│   planner/   meal plan, grocery, alert scheduling              │
└──────┬─────────────────────────────────┬──────────────────────┘
       │                                 │
┌──────▼──────────────────┐   ┌──────────▼───────────────────────┐
│ Supabase                │   │ Google Gemini API                │
│  Postgres + RLS         │   │  2.5 Flash  — extraction, chat,  │
│  Auth (email + Google)  │   │              meal planning       │
│  Storage (private)      │   │  2.5 Pro    — weekly review,     │
│                         │   │              multi-report trends │
└─────────────────────────┘   └──────────────────────────────────┘
```

`*` the safety layer is deterministic first; a cheap Flash "policy judge" only adjudicates
cases the deterministic rules mark ambiguous.

## 2. Why there is a backend at all

You asked earlier why a server is needed when everything could run on the phone. For a
**personal** app it genuinely isn't. For the app you have now described — multi-user,
public, on the Play Store — it is mandatory, for four reasons:

1. **The Gemini API key.** Anything shipped inside an APK can be extracted in minutes with
   free tools. A leaked key means strangers spend your quota, and once you move to a paid
   tier, your money. The key must never leave the server.
2. **The safety layer must not be bypassable.** If "don't prescribe medication" lives only
   in the app, a modified APK removes it. It has to run server-side.
3. **Model and prompt changes without an app update.** Users update apps slowly. If a prompt
   produces a bad answer, you fix it on the server and every user is fixed in seconds.
4. **The rules engine and nutrition database are shared assets.** Reference ranges and food
   composition tables should be curated once, centrally, not baked into each installed copy.

## 3. Database: Supabase, not Firebase — and why

You proposed Firebase. Here is an honest comparison against **your own schema sketch**,
which is relational (`users → health_reports → lab_results`, `goals`, `food_logs`, …).

| Need | Firebase (Firestore) | Supabase (Postgres) |
|---|---|---|
| Your relational schema | Document store — you must denormalise and duplicate data | Native. Your sketch maps 1:1 to tables |
| Per-user isolation | Security Rules — application-level, easy to get subtly wrong | **Row Level Security** — the database itself refuses to return another user's row |
| "Show my HbA1c over 2 years" | Multiple queries + client-side joins | One SQL query |
| Weekly summary aggregation | Cloud Function fan-out, read-count heavy | One `GROUP BY` |
| Free tier storage for reports | Cloud Storage for Firebase now requires a billing account on new projects — **verify before relying on it** | 1 GB included on the free tier |
| Free tier database | 1 GiB, 50k reads / 20k writes per day | 500 MB Postgres, no per-read cap |
| Auth | Excellent, free | Excellent, free, 50k monthly active users |
| Push notifications | FCM — best in class, free | None — see below |
| Vector search later | Needs a third service | `pgvector` included |

**Recommendation: Supabase for auth, database and file storage.** It fits your schema, and
Row Level Security gives you exactly the isolation guarantee you asked for, enforced by the
database rather than by code we might get wrong.

**Push notifications: you do not need a push service yet.** Almost every alert you listed —
meals, water, activity, sleep, grocery day — is *time-based*, and a time-based alert is
scheduled by the phone itself using Android's `AlarmManager`. It fires with the app closed
and with no internet. We add **Firebase Cloud Messaging** (free, unlimited) only in Phase 7,
for genuinely server-initiated pushes such as "your weekly summary is ready".

Known Supabase trade-off, stated plainly: **free projects pause after about a week of no
activity** and need one click in the dashboard to wake up. Fine during development; you
would move to the $25/month tier before a real public launch.

## 4. Backend hosting (free)

| Option | Card required | Cold start | Verdict |
|---|---|---|---|
| **Render free web service** | No | Sleeps after 15 min idle, ~50 s wake | **Start here.** Zero friction |
| Google Cloud Run | Yes (stays free within limits) | ~1-3 s, scales to zero, 2M req/month free | **Move here before launch** |
| Hugging Face Spaces (Docker) | No | Sleeps, public by default | Not suitable for health data |
| Fly.io / Railway | Yes | Fast | Free allowances have tightened |

We hide Render's cold start behind an honest loading state ("waking up the health
engine…"). Free-tier terms change often — check the provider's current pricing page before
you commit.

## 5. The AI is never the source of truth

Your instinct here is the single best decision in the brief, and the architecture enforces
it. See `docs/04-ai-pipeline.md` for the full pipeline. In summary:

| Concern | Owned by | Never owned by |
|---|---|---|
| Reference ranges by age/sex | Curated `reference_ranges` table | The model |
| Is this value abnormal? | Python comparison | The model |
| Is this an emergency? | Hard-coded threshold rules | The model |
| How much iron is in 100 g of ragi? | `foods` table (IFCT / USDA) | The model |
| Daily nutrient targets | ICMR-NIN RDA table | The model |
| Reading a messy PDF into structured rows | Gemini (then validated) | — |
| Explaining a result in plain English | Gemini | — |
| Composing a meal the user will actually enjoy | Gemini, **choosing only from foods we hand it** | — |
| Asking good follow-up questions | Gemini | — |

The backend **recomputes every number** the model mentions and overwrites it. If the model
says "this dosa has 12 g protein" and the database says 8.4 g, the user sees 8.4 g.

## 6. Privacy and data protection, from day one

- **Authentication required** for everything. No anonymous health data.
- **Row Level Security on every table**: `auth.uid() = user_id`. The service-role key exists
  only in the backend's environment variables.
- **Private storage bucket.** Report files are never publicly addressable; the app receives
  short-lived signed URLs.
- **Data minimisation.** After extraction we keep the structured values. Keeping the
  original file is an explicit user choice in settings, defaulting to *keep* for 90 days.
- **Consent flow** at first launch: what we collect, that analysis is sent to Google's Gemini
  API, and what the app is not (a doctor). Recorded in a `consents` table with timestamp and
  version.
- **"Delete all my health data"** — a real, tested endpoint that removes rows *and* storage
  objects, with a confirmation and a receipt. Covered by an automated test.
- **Audit trail** in `health_events` and `ai_runs`: what was generated, by which model, which
  safety verdict it got. Needed for debugging and for trust.
- **No secret in the repo, ever.** `.env.example` documents the variable names only.

> ⚠️ **Gemini free-tier caveat you must decide on.** On the free tier, Google's terms permit
> your prompts and uploads to be used to improve their products. You would be sending users'
> lab reports. This is acceptable for you testing on yourself. It is **not** acceptable once
> other people's health data flows through it — before any public release you must move to
> paid Gemini (pay-as-you-go), which excludes that, and say so in your privacy policy.
> Check `ai.google.dev/gemini-api/terms` for the current wording.

## 7. Repository layout

```
health-sentinel/
├── app/                      Flutter application
│   ├── lib/
│   │   ├── core/             theme, config, errors, formatting
│   │   ├── data/             API client, local cache, models
│   │   ├── features/         auth, onboarding, chat, reports, plan,
│   │   │                     grocery, alerts, trends, settings
│   │   ├── services/         notifications, storage, connectivity
│   │   └── main.dart
│   ├── android/
│   └── test/
├── backend/
│   ├── app/
│   │   ├── api/              FastAPI routers
│   │   ├── core/             settings, auth, logging
│   │   ├── ingest/           file handling, extraction orchestration
│   │   ├── ai/               Gemini client, prompts, response schemas
│   │   ├── rules/            reference ranges, abnormality, red flags
│   │   ├── nutrition/        foods, RDA gaps, nutrient maths
│   │   ├── planner/          meal plan, grocery, alert schedule
│   │   ├── safety/           output validator, escalation
│   │   └── repositories/     database access
│   ├── tests/
│   └── pyproject.toml
├── db/
│   ├── migrations/           versioned SQL
│   ├── policies/             RLS policies
│   └── seed/                 biomarkers, reference ranges, foods, RDAs
├── docs/
├── .github/workflows/        tests, lint, Android build
├── CLAUDE.md
└── README.md
```

This matches the folder split you asked for (mobile / backend / AI / database / docs /
tests), with AI kept inside the backend rather than as a separate deployable — one service
is far simpler to run for free, and the AI code is useless without the rules and nutrition
code next to it.
