# The HealthPulse database — how to set it up

This folder holds every piece of SQL the app needs. SQL is just text: you copy a
file, paste it into a box on the Supabase website, press Run, and Supabase builds
that part of the database for you.

**You do not need to install anything.** Everything below happens in a web
browser.

It takes about 15 minutes. Do the files **in order**, top to bottom. Each one
depends on the ones before it.

---

## Before you start

You need a Supabase project. If you do not have one yet, that is covered in
`docs/06-your-manual-steps.md` — do that first and come back.

Once you have a project:

1. Go to <https://supabase.com> and sign in.
2. Click your project.
3. In the left-hand menu click **SQL Editor**.
4. Click **New query**. You now have a big empty text box. That box is where
   everything below gets pasted.

> **A note on the word "run".** Each time this guide says *run a file*, it means:
> open the file, select all of the text (Ctrl+A / Cmd+A), copy it, click into the
> empty SQL Editor box, paste, and press the green **Run** button
> (or Ctrl+Enter / Cmd+Enter). Then clear the box before the next file.

---

## The order to run things

Run these **15 files, one at a time, in this exact order**. Tick them off as you
go — it is easy to lose your place.

### Part 1 — build the tables (8 files)

| # | File | What it builds |
|---|---|---|
| 1 | `migrations/001_extensions.sql` | Turns on two Postgres add-ons the rest needs |
| 2 | `migrations/002_identity.sql` | Your profile, health profile, allergies, consent records |
| 3 | `migrations/003_reports.sql` | Uploaded lab reports and the individual lab values |
| 4 | `migrations/004_reference_biomarkers.sql` | The medical lookup tables (biomarkers, synonyms, reference ranges) |
| 5 | `migrations/005_symptoms_goals_memory.sql` | Symptoms, goals, and things the app learns about you |
| 6 | `migrations/006_nutrition.sql` | Foods, recipes, daily nutrient targets, food diary |
| 7 | `migrations/007_plans_grocery_alerts.sql` | Meal plans, grocery lists, pantry, reminders |
| 8 | `migrations/008_chat_audit.sql` | Chat, the audit trail, the AI cost ledger, deletion receipts |

### Part 2 — lock it down (2 files)

| # | File | What it does |
|---|---|---|
| 9 | `policies/100_rls.sql` | **The important one.** Makes the database itself refuse to hand one user another user's data |
| 10 | `policies/101_storage.sql` | Creates the private `reports` file bucket and locks each file to its owner |

### Part 3 — fill in the shared data (5 files)

| # | File | What it loads |
|---|---|---|
| 11 | `seed/200_biomarkers.sql` | 82 lab tests with their proper units |
| 12 | `seed/201_biomarker_synonyms.sql` | 353 ways Indian labs spell those test names |
| 13 | `seed/202_reference_ranges.sql` | 28 cited normal/abnormal thresholds |
| 14 | `seed/203_rda_targets.sql` | 16 ICMR-NIN 2020 daily nutrient targets |
| 15 | `seed/204_foods_starter.sql` | 147 common Indian foods |

**Do not run `tests/000_local_supabase_shim.sql`.** That file is only for running
the database on a laptop or in CI. Supabase already provides what it creates, and
running it on Supabase would be confusing at best.

---

## What "it worked" looks like

Some files print a small table of numbers when they finish. That is on purpose —
they are checking themselves. Here is what each check should say.

**After file 9 (`100_rls.sql`)** — look in the messages area under the results.
You want to see:

```
NOTICE:  RLS enabled on every table in schema public.
```

If instead you get a red error saying *"RLS is NOT enabled on: ..."*, something
did not run. Go back and re-run the migration files, then this one again.

**After file 10 (`101_storage.sql`)**:

```
NOTICE:  Private reports bucket present, 4 owner-scoped policies installed.
```

**After the seed files** — each prints its own count:

| File | Should print |
|---|---|
| `200_biomarkers.sql` | `biomarkers_loaded = 82` |
| `201_biomarker_synonyms.sql` | `synonyms_loaded = 353`, and a second, **empty** table |
| `202_reference_ranges.sql` | `ranges_loaded = 28`, `biomarkers_covered = 21`, then an **empty** table, then a long list of biomarkers that have no range yet (this is expected — see `seed/GAPS.md`) |
| `203_rda_targets.sql` | `rda_targets_loaded = 16` |
| `204_foods_starter.sql` | `foods_loaded = 147` |

An **empty** result table where the file says "this must return 0 rows" is a pass,
not a failure. It means nothing is broken.

---

## The one check that really matters

Everything above just builds things. This next step proves the privacy promise:
that the database physically refuses to show one user another user's health data.

Run `tests/rls_smoke.sql` exactly the same way — copy, paste, Run.

It quietly creates two pretend users, has each of them save a report, a lab
result and a chat message, and then tries 20 different ways for the first user to
peek at the second user's data. Then it undoes all of it, so nothing is left
behind in your database.

In the messages area you should see 21 green-ish lines, ending with:

```
NOTICE:  PASS 20: A cannot WRITE to reference data (service role only)
NOTICE:  --------------------------------------------------
NOTICE:  ALL 20 RLS CHECKS PASSED
NOTICE:  --------------------------------------------------
```

and a final table reading `leftover_test_users = 0`, `leftover_junk_rows = 0`.

**If any line says FAIL, stop.** Do not connect the app. Re-run
`policies/100_rls.sql`, then run the test again.

---

## A quick look at what you built

Paste this into a new query to see all 34 tables and confirm the lock is on
every one of them:

```sql
select c.relname as table_name,
       c.relrowsecurity as row_level_security_on
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;
```

You should get 34 rows and every value in the second column should be `true`.

---

## Running a file twice by mistake

That is fine. Every file in this folder is written to be safe to run again:

- tables use `create table if not exists`,
- policies are dropped and recreated,
- seed data uses `on conflict do nothing`.

Running a file a second time changes nothing and loses nothing. If you lose your
place, the safest thing is to start at file 1 and run them all again in order.

---

## Things you should know about this database

### 1. Privacy is enforced by the database, not by the app

Every table that holds your data has **Row Level Security** switched on. The rule
is `auth.uid() = user_id` — "you may only touch rows that are yours".

This matters because it holds even if the app has a bug. A wrong query does not
leak someone's blood test; it returns nothing.

Tables that do not have a `user_id` of their own — the extraction of a report,
the items in a meal plan, the lines on a grocery list — check their **parent**
instead. A meal plan item is yours if the meal plan it belongs to is yours.

### 2. Four tables can be added to but never edited or erased

`consents`, `health_events`, `ai_runs` and `deletion_requests` allow *select* and
*insert* only. They are records of what happened — a consent you gave, an alert
that fired, a model call that was made, a deletion you asked for. A record you
could quietly edit afterwards would be worthless.

"Delete all my health data" still removes them. That runs on the server with the
service role key, which is allowed to bypass these rules. That key lives only in
the backend's environment variables and never in the app.

### 3. The shared tables are read-only to everyone

`biomarkers`, `biomarker_synonyms`, `reference_ranges`, `foods`, `recipes`,
`recipe_items` and `rda_targets` are shared by all users. Logged-in users can
read them. **Nobody signed into the app can change them** — only the backend,
using the service role key. That is what stops a bad actor from editing what
"normal haemoglobin" means.

### 4. Report files are private

`101_storage.sql` creates a bucket called `reports` with `public = false`. Files
must be saved at the path:

```
reports/<your user id>/<file name>
```

The first folder **must** be your user id — that is the whole security check. A
file saved anywhere else is invisible to everyone. The app never gets a public
link to a report; it asks the backend for a short-lived signed URL.

### 5. Some medical thresholds are deliberately missing

`seed/202_reference_ranges.sql` only contains numbers we could point to a
published guideline for. Where we were not sure, **we left the row out instead of
guessing**, and wrote down what is missing in `seed/GAPS.md`.

So 61 of the 82 lab tests can be read and stored but not yet judged
normal/abnormal. That is the correct, safe state for a health app to be in. The
backend must treat "no threshold" as *"we cannot say"* — never as *"normal"*.

Please read `seed/GAPS.md` before showing this to anyone medical. It is written
for exactly that conversation.

### 6. The food numbers are placeholders

All 147 foods load with `source = 'PROVISIONAL'`. The values are typical
published figures, good enough to build and test against, but they have not been
checked line by line against IFCT 2017 or USDA. Before real users see a nutrient
number, those rows need replacing with a verified import. `seed/GAPS.md` explains
how.

---

## Folder contents

```
db/
├── README.md                              this file
├── migrations/                            builds the 34 tables, run 001 -> 008
│   ├── 001_extensions.sql
│   ├── 002_identity.sql
│   ├── 003_reports.sql
│   ├── 004_reference_biomarkers.sql
│   ├── 005_symptoms_goals_memory.sql
│   ├── 006_nutrition.sql
│   ├── 007_plans_grocery_alerts.sql
│   └── 008_chat_audit.sql
├── policies/                              the privacy rules, run after migrations
│   ├── 100_rls.sql
│   └── 101_storage.sql
├── seed/                                  the shared data, run after policies
│   ├── 200_biomarkers.sql
│   ├── 201_biomarker_synonyms.sql
│   ├── 202_reference_ranges.sql
│   ├── 203_rda_targets.sql
│   ├── 204_foods_starter.sql
│   └── GAPS.md                            what is missing, and why
└── tests/
    ├── 000_local_supabase_shim.sql        ONLY for a laptop / CI, never Supabase
    └── rls_smoke.sql                      proves the privacy rules work
```

---

## For engineers: running this without Supabase

On a plain PostgreSQL 15 or 16 server (a laptop, or CI):

```bash
createdb healthpulse

psql -d healthpulse -v ON_ERROR_STOP=1 -f db/tests/000_local_supabase_shim.sql

for f in db/migrations/*.sql db/policies/*.sql db/seed/*.sql; do
  psql -d healthpulse -v ON_ERROR_STOP=1 -f "$f"
done

psql -d healthpulse -v ON_ERROR_STOP=1 -f db/tests/rls_smoke.sql
```

The shim creates just enough of Supabase — the `auth` and `storage` schemas, the
`anon` / `authenticated` / `service_role` roles, `auth.uid()` and
`storage.foldername()` — for the real files to run unmodified. Exit code 0 from
the last command means all 20 isolation checks passed.

---

## Vocabularies the backend must match exactly

These strings are enforced by CHECK constraints. If the backend sends anything
else, the insert is rejected — which is the point.

| Column | Allowed values |
|---|---|
| `health_profiles.sex` | `male` `female` `other` `prefer_not_to_say` |
| `health_profiles.activity_level` | `sedentary` `moderate` `heavy` (ICMR-NIN's own three groups) |
| `health_profiles.diet_type` | `veg` `non_veg` `egg` `vegan` `jain` |
| `reports.status` | `uploaded` `extracting` `extracted` `failed` |
| `lab_results.status` | `critical_low` `low` `borderline_low` `normal` `borderline_high` `high` `critical_high` |
| `goals.goal_type` | `weight` `hair` `skin` `energy` `sleep` `fitness` `deficiency` |
| `food_preferences.stance` | `like` `dislike` `neutral` `never` |
| `food_logs.source` | `planned` `chat` `photo` `manual` |
| `food_feedback.rating` | `1`–`5` |
| `grocery_items.state` | `need` `have` `bought` |
| `alerts.alert_type` | `hydration` `meal` `grocery` `activity` `sleep` `nutrition` `report_followup` `weekly_summary` `escalation` |
| `chat_messages.role` | `user` `assistant` `system` |
| `foods.source` | `IFCT2017` `USDA` `PROVISIONAL` |
| `rda_targets.source` | `ICMR-NIN 2020` |
| `reference_ranges.sex`, `rda_targets.sex` | `male` `female` `any` |
| meal slots (`food_logs`, `meal_plan_items`) | `breakfast` `mid_morning` `lunch` `snack` `dinner` `bedtime` |
