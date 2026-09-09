# Product definition and safety charter

## What we are building

**HealthPulse** — an AI health and nutrition **coach**. Not a diagnostic tool, not a doctor,
not a pharmacy.

A user uploads lab reports, scans, prescriptions and food photos, and talks to it in chat.
It extracts the data, checks it against real medical reference rules, and turns it into a
plan they can act on today: what to eat at breakfast and *why*, how much water, when to
sleep, what to buy at the weekend — and it keeps adjusting as it learns what they actually
eat and enjoy.

**The loop is the product.** A one-shot "here is what your report means" is a commodity;
ChatGPT does it for free. What almost nothing does well is the seven-day-a-week follow
through:

```
health data → analysis → goals → personalised plan → daily actions
    → alerts → user feedback → updated preferences → better next plan
                    └──────────────── repeats forever ───────────────┘
```

## Positioning sentence

> HealthPulse reads your health reports and your habits, and turns them into daily food,
> hydration, sleep and activity guidance that fits what you actually like to eat — and tells
> you plainly when something needs a doctor.

## Safety charter

This is the section that must never be diluted. It is duplicated in `CLAUDE.md` so that
every future session sees it.

### The app MAY
- Explain a lab value in plain language.
- Flag values outside reference range as "worth discussing with a doctor".
- Suggest foods, meals, portion sizes, hydration, sleep and activity.
- Suggest ordinary kitchen/home practices (soaking, sunlight exposure, food pairing for iron
  absorption).
- Track goals, meals, habits, progress; build grocery lists.
- Explain *why* a food helps, using our nutrition database.
- Send reminders and nudges.
- Tell the user what to ask their doctor, and when to go.

### The app MUST NOT
- Prescribe, name, recommend or change any **medication**.
- Give a **dose** — including supplement doses. *"Take 60,000 IU vitamin D weekly"* is a
  prescription. *"Your vitamin D is low. Sunlight and these foods help. Ask your doctor
  whether you need a supplement and at what dose"* is coaching. **This distinction is the
  line.**
- State a **diagnosis**. Not *"you have diabetes"* but *"this HbA1c pattern is one doctors
  look at for diabetes — please get it confirmed"*.
- Tell anyone to stop, skip or delay a prescribed treatment.
- Downplay a red-flag symptom or a critical value.

### Three independent enforcement points
1. **Persona / system prompt** — `backend/app/ai/prompts/`.
2. **Deterministic validator** — `backend/app/safety/`. Drug dictionary, dosage regex,
   diagnosis phrasing. Runs on **every** model output before it reaches a user. Cannot be
   bypassed by a modified app.
3. **UI** — permanent disclaimer; undismissable escalation card for `urgent` findings.

A model output that fails validation is regenerated once with the violation quoted back; a
second failure falls back to a safe templated response. Every verdict is logged.

## Feature set

**Core (Milestone 1)** — auth, health profile onboarding, chat with attachments, report
upload and extraction, abnormality detection, personalised summary, daily plan.

**Then** — meal planner with nutritional reasoning · food logging by chat/photo/tap ·
1-5★ feedback · preference learning · alerts (hydration, meal, activity, sleep, grocery,
report follow-up) · weekly grocery list with have/need checkboxes · pantry · weekly and
monthly summaries · trends per biomarker · goal progress · safety and escalation ·
data export and delete.

## Ideas worth adding (you asked for more)

Ranked by value-for-effort. None are in Milestone 1.

1. **"Why did my plan change?" feed** — every plan change shown with its reason. Makes the
   learning visible. Cheap to build, disproportionate effect on trust.
2. **Doctor visit pack** — a one-page PDF: current values, trend arrows, symptoms logged,
   questions to ask. Genuinely useful, and it positions the app as *supporting* doctors
   rather than replacing them, which matters for Play Store review.
3. **Re-test scheduler** — "your vitamin D was low on 14 Aug; retest around 14 Nov", with a
   calendar reminder. Closes the loop that most health apps drop.
4. **Eat-out mode** — photograph a restaurant menu, get the two best choices for today's
   plan. High delight, uses machinery we already have.
5. **Family profiles** — one account, several members (parents' reports). Very common need
   in India. Needs careful consent design.
6. **Cook-time filter** — "I have 15 minutes" reshuffles the plan to quick recipes.
7. **Streaks and a weekly score** — habit-forming, but keep it gentle; guilt-driven health
   apps get uninstalled.
8. **Offline day view** — today's plan cached locally so the app is useful with no signal.
9. **Shared grocery list** — export to WhatsApp for whoever shops.
10. **Voice logging** — "I had two idlis and sambar" while walking away from the table.

Deliberately **not** doing: symptom-checker triage, medication reminders (that is a
regulated space and invites exactly the prescribing risk we are avoiding), and wearable
integration (Google Fit/Health Connect) until the core loop is proven.
