# Build plan

Your nine phases, kept in your order, with what each one actually produces and who does
what. **M** = a manual step only you can do (see `docs/06-manual-steps.md`).

| Phase | Produces | Blocked on |
|---|---|---|
| **0 · Foundations** | Repo structure, CI, DB schema + RLS + seed data, `.env.example`, contracts | **M1** Supabase project |
| **1 · Foundation app** | FastAPI service, Supabase auth, Flutter shell, login, profile onboarding, chat UI, file upload, Gemini wired end-to-end | **M2** Gemini key in Render, **M3** Render service |
| **2 · Report intelligence** | Extraction, normalisation, classification, abnormal detection, report summary, per-biomarker history | Phase 1 |
| **3 · Personalisation** | Food/goal/preference model, `user_memory`, feedback capture, preference block builder | Phase 2 |
| **4 · Meal planner** | Daily plan with per-item nutrient reasoning, recomputed server-side from `foods` | Phase 3, **M6** food data seed |
| **5 · Alerts** | Alert engine, device-local scheduling, per-type toggles, quiet hours | Phase 4 |
| **6 · Grocery** | Weekly list, aisle grouping, have/need/bought, pantry, replenishment | Phase 4 |
| **7 · Long-term intelligence** | Weekly + monthly summaries (2.5 Pro), trend charts, goal progress, "why did my plan change" | Phase 5, 6 |
| **8 · Safety** | Red-flag rules, escalation cards, output validator, uncertainty handling, doctor-visit pack | Runs alongside from Phase 2; hardened here |
| **9 · Release** | Icon, splash, privacy policy, terms, delete-my-data, signing, APK + AAB, listing | **M7** keystore, **M8** privacy policy URL, **M9** Play Console |

**Milestone 1** (your stated first goal) = Phases 0–2: an installable Android app with
login, profile, chat, upload, Gemini analysis and a personalised summary.

## How the build runs

Work is split across parallel agent teams with a fixed contract between them, so the pieces
fit when they meet:

| Team | Owns | Verifiable here? |
|---|---|---|
| **DB** | `db/migrations`, RLS policies, seed data | SQL reviewed, applied by you against Supabase |
| **Rules & Nutrition** | `backend/app/rules`, `backend/app/nutrition` | **Yes — pure Python, full pytest suite** |
| **AI & Safety** | `backend/app/ai`, `backend/app/safety` | **Yes — pytest with mocked Gemini** |
| **API** | `backend/app/api`, `core`, `repositories` | **Yes — pytest + FastAPI TestClient** |
| **App** | `app/` Flutter | No Dart toolchain here — **CI is the compiler** |
| **CI/Release** | `.github/workflows`, signing, packaging | Yes, once CI runs |

## Honest constraint

This container has Python 3.11 (so the whole backend is genuinely tested before you ever see
it) but **no Flutter or Android SDK**. The Flutter code is written carefully and reviewed,
but the first GitHub Actions run is its compiler. Expect one or two red builds on the app
while analyzer errors are fixed. That is normal and I will drive them to green rather than
hand you a red pipeline.

## Definition of done, per phase

1. Tests pass in CI.
2. No secret anywhere in the repo.
3. RLS proven by a test that tries to read another user's row and is refused.
4. Safety validator has a test per forbidden category (medication, dose, diagnosis, stop
   treatment).
5. Docs updated.
6. Pushed to `main`.
