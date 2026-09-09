# Decisions

Resolved 9 September 2026. The owner asked for "the end result, not the prototype" on
every axis, so where a decision offered an easy interim option and a production one, the
production one is recorded here.

| # | Decision | Chosen | Note |
|---|---|---|---|
| D1 | Product name | **HealthPulse** | Repo stays `health-sentinel`. ⚠️ Still to do: search the Play Store and a trademark register before this goes on an icon |
| D2 | Database | **Supabase** (Postgres + RLS + Auth + Storage) | Relational schema, isolation enforced by the database |
| D3 | Push | **Local notifications AND Firebase Cloud Messaging** | See below — this one is not either/or |
| D4 | Backend host | **Google Cloud Run**, with Render as the working stopgap | See below |
| D5 | Auth | **Multi-user with real auth from day one** | |
| D6 | Food data | **Indian foods first** (IFCT + USDA), English UI | |
| D7 | iOS | **Code kept iOS-clean; iOS shipped in Phase 9** | Needs a Mac and $99/year — a hard external constraint, not a code one |
| D8 | Signing | **Proper upload keystore** | Manual step M7 |

## D3 — why this is not either/or

The choice was framed as local notifications *or* FCM, and that framing was wrong. A
production system wants both, because they solve different problems:

- **Device-local notifications** handle everything time-based: meals, water, sleep,
  activity, grocery day. The phone's own alarm clock fires them. They work with the app
  closed, with no network, and with the backend asleep. Routing these through a server
  would make them *less* reliable, not more.
- **Firebase Cloud Messaging** handles what only the server knows: your weekly summary
  finished generating, a re-test is due, a newly uploaded report finished analysing.

Both ship. Local notifications carry the daily loop; FCM carries server-initiated events.

## D4 — why Render is still in the picture

Cloud Run is the right production target: it scales to zero, wakes in about a second, and
2 million requests a month are free. It needs a card on file even though the usage stays
free.

Render is already provisioned and its free instance sleeps after 15 minutes, waking in
around 50 seconds. That is a bad experience for a health app you open in the morning.

So: Render stays as the working deployment while the API is built, and Cloud Run becomes
the target before anyone but the owner uses the app. Both are described in
`docs/06-your-manual-steps.md`. Nothing in the code depends on which one is running.

## Still open

1. **The four clinical conflicts** in `db/seed/GAPS.md` — the vitamin D cut-off in
   particular changes how many users get flagged. These want a clinician, not a developer.
2. **Age coverage.** Seeded reference ranges and RDAs cover adults 19–59. There are no
   paediatric ranges beyond haemoglobin and no pregnancy ranges beyond haemoglobin. Until
   that is commissioned, **the app is adults-only in practice** and should say so.
3. **Gemini tier.** The free tier permits Google to use uploads for product improvement.
   Acceptable while the owner tests on their own reports. Not acceptable once other
   people's health data flows through it — paid tier before public release.
