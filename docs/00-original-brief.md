# Original brief (owner's own words)

> Saved verbatim at the owner's request, 9 September 2026. This is the source of truth for
> intent. If anything in the design contradicts this document, the design is wrong or the
> deviation must be recorded in `docs/07-open-decisions.md` with a reason.

## Part 1 — the idea

I am thinking of building an app.

What this app would do is, suppose someone comes into the app and uploads a lab report, a
scan report, or something similar. The app should behave somewhat like a health doctor
specifically for that person and tell them what they should take, what they should do, and
what they should follow.

For example, the app should have a chat window where the user can communicate through
messages. The user should also be able to upload any document, any photo, or basically any
type of attachment.

Now, what we need to do is, whatever attachment the user has uploaded, the app should
analyze all of it and then provide a clear-cut plan based on that analysis.

After providing the plan, we should not stop there. We should also suggest, preferably
through alerts, what changes the user needs to make in their diet. For example, what they
should eat in the morning, what they should eat in the afternoon, what they should eat at
night, and what healthy habits they should follow — all of these should be based on their
lab reports and also based on the user's preferences.

For example, maybe a user does not like certain foods or does not want to eat certain
things. At the same time, the user still wants to follow a plan to correct whatever issue
was identified in their lab report. So, what we should try to do is make both things happen
together — the foods that the user likes and the foods or nutritional requirements that are
needed to improve whatever was identified in the lab report.

So, we can try to build something like a health alert system.

Every day, we are collecting the user's preferences. For example, we are collecting
information about what the user eats every day, what they do not eat, what they like, what
they do not like. That information should also continuously be fed into our system. The
system should keep learning these things over time. Based on this information, the system
should prepare a plan.

Suppose the user uploads one lab report. But later, if the user comes into the chat box and
says that they are experiencing hair loss, our app should also consider that information and
include something related to hair loss in the user's plan. Similarly, if the user says "I
want to improve my skin glow", the app should also consider that requirement. Whatever the
user tells the app, we should consider all of those things and provide them as part of the
alerts or recommendations.

If the app recommends a particular food, it should explain why that food is useful. Suppose
on Monday morning the user is supposed to eat a particular food item. The app should tell
the user that if they eat this food on Monday morning, it can provide a particular benefit.
It should also explain things like: this food contains this much fiber, it contains this
much of a particular vitamin, this is beneficial for you. All of these things should be
available based on the user's preferences. The entire system should be interactive with the
user. The app should communicate with the user continuously.

At the end of the day, I want an ultimate health alert system, and everything in that system
should be personalized specifically for that particular user. For every person who installs
the app, their preferences and requirements will be different. So each user's information
should be maintained separately.

As far as possible I want to use whatever databases, models, APIs or other technologies are
available for free. But at the end of the day I want a very good product, a very good
application, and a good APK file that I can install on my phone. I also want the app to be
something that I can eventually release publicly, and if possible publish on the Google Play
Store.

## Part 2 — positioning and safety

The app should not present itself as a doctor or independently prescribe medicines or
treatments. Personal home remedies and dietary plans are fine. But it should not prescribe
any medicines — I am pretty sure about that.

It should be something like an AI health assistant / health coaching system that analyses
uploaded information, identifies possible issues, provides evidence-based lifestyle and
nutrition guidance, and clearly tells the user when a doctor should be consulted.

It continuously understands the user's health reports, symptoms, diet, goals, preferences,
habits and progress, and then turns them into daily actionable health guidance and alerts.

It is a continuous process. It should not be "upload the report and AI explains the report".
It is:

    health data -> analysis -> goals -> personalised plan -> daily actions
    -> alerts -> user feedback -> updated preferences -> better future plans

**AI can:** explain reports, summarise findings, suggest healthy lifestyle habits, track
goals, track meals, generate grocery lists, give general nutrition options, prompt
reminders, identify questions to discuss with a doctor, and explain why a food is
nutritionally relevant.

**AI should not:** independently prescribe medication, change medical dosages, or make
serious disease diagnoses.

## Part 3 — the pieces

**Health profile:** age, sex, height, weight, activity level, food preferences (vegetarian /
non-vegetarian), allergies, foods they dislike, foods they like, typical meal timings, sleep
schedule, exercise habits, health goals, and maybe location for food and grocery
availability.

**Upload system:** blood test reports, urine reports, thyroid reports, vitamin reports,
lipid profile, diabetic reports, doctor prescriptions, food images, medical documents and
scan reports. For every report extract all the information — test name, result, units, date,
laboratory, everything. Then identify potential abnormal values, trends and missing
information.

**Goals:** the user can say "I want to reduce my weight", "I want better skin", "I am
experiencing hair loss", "I want to improve my energy", "I want to improve my diet" — and
the system creates separate goals for each: improve nutritional deficiencies, improve diet
quality, support healthy hair, improve sleep, improve fitness.

**Preference engine:** multiple food preferences, likes and dislikes, meal timings. Basic
information is captured at the start (name, age, sex). Over time the app learns what the
user frequently eats, frequently skips, dislikes, and prefers.

**Guidance style:** instead of simply saying "eat more protein", the app should say "it's
Monday, it's breakfast time, and it is good to have egg + vegetable dosa" — and why: the
protein contribution, the fibre contribution, and that it fits your preferences. Then lunch.
Then dinner.

**Food feedback loop (very important):** the app should ask "what did you eat for
breakfast?". The user may answer in chat or upload an image. The system records it. Then it
asks "did you enjoy it?" — with emojis or a 1-5 rating, or loved it / OK / disliked it. Over
time it collects preferences: eggs loved, dosa loved, oats disliked, soya chunks disliked,
chicken loved.

**Grocery intelligence (one of our strongest ideas):** if the app suggests a weekly meal
plan, the user can get the whole grocery list at the weekend from a dedicated tab, so they
can buy everything and prepare the food. The user can mark each item "already have" or "need
to buy" with a checkmark in the app.

**Alerts:** hydration alert, food alert, grocery alert, activity alert, sleep alert,
nutrition alert, latest-report alert, follow-up alert.

**Chat behaviour:** if the user says "my hair is falling a lot", the app should not just say
"I understand your problem, here is what to do". It should ask follow-up questions — when
did it start, is it sudden or gradual, any recent illness, any significant stress, any scalp
symptoms — and then plan accordingly.

**Weekly and monthly summaries:** meals logged, water goal, exercise days, sleep time, foods
you liked, foods you did not like, recommended meals followed.

## Part 4 — technology thoughts

For the initial prototype, use Gemini 2.5 Flash for cost-sensitive multimodal work, and
reserve a stronger model such as Gemini 2.5 Pro for complex reasoning and review tasks where
needed.

I would not make the LLM the medical source of truth. Instead:

    medical knowledge -> trusted knowledge sources -> rules / validation
    -> LLM reasoning -> safety layer -> user

The LLM should be the reasoning interface layer only.

For the database, for the first version maybe Firebase — Firebase Authentication, Firestore,
Firebase Storage, Crashlytics, Analytics, Cloud Messaging. I am not sure about that, so
suggest the best approach.

Health information is very sensitive, so the database must be designed properly. Something
like: users (user_id), profiles (user_id), health_reports (report_id, user_id), lab_results
(result_id, report_id), symptoms (symptom_id, user_id), goals (goal_id, user_id), food
preferences (user_id), meal_plans (user_id), food_logs (user_id), grocery_items (user_id),
alerts (user_id), health_events (user_id). Every user's data must be isolated by user_id and
protected by authentication and authorisation rules. Correct me if I am wrong, and suggest
simpler approaches — I am open to adopting your approach.

For mobile, Flutter, because of Android APK and Google Play, and because Flutter also
supports iOS later. For the backend, Python + FastAPI. Architecture something like Flutter ->
FastAPI -> AI services -> Firebase.

Repository layout: mobile application in one folder, backend application in one folder, AI
services in one folder, database schemas in one folder, a docs folder, a test folder, a
complete README and a usage guide.

**Privacy must be built in from day one.** We are dealing with lab reports, medical
documents, symptoms, food habits, potential medications and personal information. So:
authentication, minimal data collection, secure storage, a "delete my data" function, and a
privacy policy and consent flow. The user should be able to say "delete all my health data"
and the system should actually delete it.

Initial stack: Flutter, FastAPI, Python, Gemini, Firebase (Firestore, Storage, Auth, Cloud
Messaging, Analytics, Crashlytics), GitHub, GitHub Actions, Postman, Figma, Google Play
Console.

## Part 5 — phases

1. **Foundation** — Flutter app, login, user profile, chat UI, file upload, backend,
   Firebase and Gemini integration.
2. **Report intelligence** — PDF upload, image upload, OCR extraction, lab value extraction,
   report summary, abnormal value detection, structured health profiles.
3. **Personalisation** — food preferences, health goals, dietary restrictions, meal
   preferences, user memory, feedback system.
4. **Meal planner** — breakfast, lunch, dinner, snacks, nutritional explanation, daily plans.
5. **Alerts** — meal reminders, water reminders, activity, health report follow-ups,
   personalised notifications.
6. **Grocery system** — weekly grocery list, inventory, consumed items, remaining items,
   automatic replenishment suggestions.
7. **Long-term intelligence** — weekly reports, monthly reports, health records, health
   trends, goal progress, recommendation improvements.
8. **Safety** — emergency detection, medical safety rules, uncertainty detection, doctor
   escalation.
9. **Release** — app icon, splash screen, privacy policy, terms, data deletion, app signing,
   APK and AAB, Play Store listing, testing, production release.

**First milestone:** a working Android app with login, profile, chat, report/image upload,
Gemini analysis and a personalised health summary. Once that works, add the meal planner,
food logging, alerts, grocery, long-term personalisation, safety layer, and then production
release.

## Part 6 — name

Candidate names: Health Pulse AI, My Health AI, HealthMate AI.

## Part 7 — working agreement

I am new to this project, so I need a complete step-by-step guide in very simple English. If
any phase needs manual intervention from me — like creating the repository, which I did
myself — tell me clearly what to do and how to do it, and I will do it. If you get stuck
anywhere, tell me and I will help.
