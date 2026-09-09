# HealthPulse — Flutter app

The Android app for HealthPulse: an AI health and nutrition **coach**, not a doctor.
This is the Phase 1 foundation — the design system, the navigation shell and every
Phase 1 screen, running end to end against an in-memory fake repository. No screen
talks to a network yet, and no secret exists anywhere in this directory.

## Running it

You need the Flutter SDK (stable) and the Android SDK. There is no Flutter toolchain
in the environment these files were written in, so **GitHub Actions is the first
compiler this code meets** — see *Known risks* at the bottom.

```bash
cd app
flutter pub get          # also injects android/gradle/ and android/gradlew
flutter run              # a device or emulator running Android 8.0 or newer
flutter test             # widget, model and accessibility tests
flutter analyze          # lints
flutter build apk --release
```

The Gradle wrapper (`android/gradlew`, `android/gradle/wrapper/`) is **not committed**.
The Flutter tool writes a matching wrapper and jar on the first Android build; a
properties file committed without its jar breaks that, which is why both are ignored.

`pubspec.lock` is not committed either — it is resolved by CI rather than hand-written
without a Dart SDK.

## Configuration — the three `--dart-define` values

Nothing in this directory contains an address or a key. All three values are
supplied at **build time** and default to empty, so a fresh clone builds an app
that opens on a calm "Not connected yet" screen rather than one that crashes on
its first request or hangs on a socket that will never connect.

```bash
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY \
  --dart-define=API_BASE_URL=https://YOUR-BACKEND.onrender.com
```

The same three flags work with `flutter run`, `flutter build appbundle` and
`flutter test`:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY \
  --dart-define=API_BASE_URL=https://YOUR-BACKEND.onrender.com
```

If you have many flags, `--dart-define-from-file=env.json` takes them from a
JSON file instead. **Add that file to `.gitignore`.** It is not committed here,
and CI does not pass any of these flags: an APK built by CI is deliberately an
unconfigured one.

| Define | What it is | Secret? |
|---|---|---|
| `SUPABASE_URL` | `https://<project>.supabase.co` | No — an address. |
| `SUPABASE_ANON_KEY` | The **publishable** anon key | No. It is designed to ship in a client; every table it can reach is fenced by Row Level Security. |
| `API_BASE_URL` | The root of our own FastAPI service | No — an address. |

**The service-role key must never appear anywhere under `app/`.** It bypasses
Row Level Security completely, so one inside an APK hands every user's health
data to anyone who unzips it. `AppConfig` reads the `role` claim out of whatever
key it was given and refuses to start the app if it is not `anon`
(`test/core/app_config_test.dart` covers it). The Gemini key never comes near
this directory at all — the app talks to our backend, and the backend talks to
Gemini.

### What happens when a value is missing

The app opens on `/not-configured`, which names the missing defines, shows the
command above, and offers a way through to the sample data. It never shows a
key, a fragment of a key, or an exception. `FakeHealthRepository` stays the
default in that state, which is also what every widget test runs against.

### Release signing

`flutter build apk --release` works on a fresh clone: if `android/key.properties` is
absent, the release build falls back to debug signing so CI can still produce an
installable artifact. When the upload keystore exists (manual step **M7**), create
`android/key.properties` — never committed — with:

```properties
storeFile=/absolute/path/to/upload.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

## What is here

```
app/
├── android/                     hand-written, no wrapper, no PNG icons
│   ├── settings.gradle          AGP 8.7.3 · Kotlin 2.1.0
│   ├── build.gradle
│   ├── gradle.properties
│   └── app/
│       ├── build.gradle         compileSdk 35 · minSdk 26 · Java 17 · desugaring
│       └── src/
│           ├── main/AndroidManifest.xml      permissions + the three
│           │                                 flutter_local_notifications receivers
│           ├── main/kotlin/…/MainActivity.kt
│           ├── main/res/                     XML-only adaptive icon + splash
│           ├── debug/AndroidManifest.xml
│           └── profile/AndroidManifest.xml
├── assets/fonts/                Literata + Hanken Grotesk (OFL-1.1)
├── lib/
│   ├── core/
│   │   ├── theme/               colours, type, spacing, radii, elevation,
│   │   │                        severity, Material 3 themes for both modes
│   │   ├── widgets/             the design system
│   │   ├── format/              dates, times, numbers
│   │   └── router/              go_router configuration
│   ├── data/
│   │   ├── api/                 http client, problem+json error mapper,
│   │   │                        cold-start handling, wire ↔ model mapping
│   │   ├── cache/               sqflite offline store + staleness
│   │   ├── models/              plain Dart, hand-written fromJson/toJson
│   │   ├── repository/          HealthRepository, FakeHealthRepository,
│   │   │                        HttpHealthRepository
│   │   └── providers.dart       Riverpod wiring
│   ├── services/                Supabase auth gateway, alert scheduling
│   │                            arithmetic, local notifications
│   ├── features/                splash · consent · auth · profile setup ·
│   │                            shell · today · reports · plan · chat · more
│   ├── app.dart
│   └── main.dart
└── test/                        widget, model, format and accessibility tests
```

## Design rationale

### The problem the design has to solve

Someone opens this at 6:50 in the morning, before tea, and again after dinner. It has
to be legible while half awake, warm enough to come back to seven days a week, and
serious enough to be trusted with a lab report — without ever feeling like a hospital
corridor or a fitness tracker shouting about streaks. Nothing here should read as a
default Material template, because a health coach that looks like a framework demo is
a health coach nobody hands their reports to.

### The one memorable structure: the day as a ribbon

Today is built as a single vertical ribbon of time from waking to sleeping, with the
current moment marked, rather than as a grid of statistic cards. That is not a
stylistic flourish: the product *is* the loop, and the loop happens at particular
hours — `wake_time`, `sleep_time`, `meal_times`, the reminder that fires at four. The
home screen is that spine. Everything else on the screen is deliberately quiet so the
ribbon, and any escalation above it, are what the eye finds first. Boldness is spent
once.

### Colour

The ground is a pale herbal sage (`#EDF1EA`) — steam and kitchen herbs, not clinical
white and not the warm cream that every generated interface currently reaches for. Ink
is a deep pine-black (`#0F241E`): a green-black with a real hue, so body text reads
warm rather than stark.

There is exactly **one** brand colour, pine `#1D5C4A`, and exactly **one** warm accent,
marigold `#E0A32E`. Marigold is spent only on "now" and on progress — never on
decoration, and never as the sole carrier of meaning, because at 1.9:1 against the
ground it could not carry meaning safely even if we wanted it to. That is why the
current moment on the timeline is *also* labelled "Now" in words.

Severity has its own separate, functional ramp — calm, watch, attention, urgent,
unknown — so a warm accent can never be mistaken for a warning. Each level has its own
icon *shape* and its own word as well as its own colour, and a test asserts that all
five icons differ.

Dark mode is a full second palette rather than an inversion, on a deep forest ground
(`#0D1512`), because this app is opened in bed.

### Typography

Two families, bundled rather than downloaded, each with a job:

- **Literata** — a low-contrast, bookish serif with sturdy lining figures — carries
  numbers and the one headline per screen. A haemoglobin value should read like a line
  in a well-set book, not a readout from a machine. Using a serif for the figures is
  the single decision that most stops this looking like every other Material health
  app.
- **Hanken Grotesk** — open apertures, tall x-height — carries every label, button and
  paragraph of interface copy, sized generously for the reader in their sixties going
  through their own report. That reader is a real part of this audience.

Nothing is set in capitals. Tracked-out capital eyebrow labels are the standard
dressing of a template, and on a health screen they read as shouting.

### Structure carries information

Section rules are not decoration: the hairline runs to whatever the section has to say
about itself — "4 measured", "usual range shaded", "from the foods table" — so the line
carries a fact instead of drawing a box. Numbered markers appear in exactly one place,
the profile wizard, because that is the only part of the app that genuinely is a
sequence.

Not everything is a card. A raised surface means "this is something you can act on" — a
meal you can swap, a report you can open. Rows that are only information stay on the
ground. There are four radii, not one: pills are round, cards are soft, inputs are
squarer so they read as somewhere to type, and the escalation card keeps a square
leading edge so it cannot be mistaken for the cards around it.

Motion is one orchestrated moment, not scattered effects: things move when a person
acts, and not otherwise.

### Copy

Words are design content. Buttons name what happens and keep the same word through the
flow ("Save profile" produces "Profile saved"). Empty screens invite rather than
apologise. Errors say what happened and what fixes it, in the interface's voice.
Loading says the honest thing — the free hosting tier really does take a moment to wake
up, and pretending otherwise makes the app feel broken.

And no string in this app diagnoses or prescribes. "You have a vitamin D deficiency" is
wrong twice over; "Your vitamin D is below the usual range — sunlight and these foods
help, and it is worth asking your doctor whether you need more than that" is the voice.
`test/safety_copy_test.dart` runs a regular-expression check over every sample string to
keep placeholder copy honest.

## Safety, as implemented here

The UI is the third of three independent enforcement points named in
`docs/01-product-and-safety.md`. The other two — the model persona and the
deterministic server-side validator — live in the backend, where a modified APK cannot
reach them.

| Requirement | Where it lives |
|---|---|
| Disclaimer visible wherever health data is interpreted | `HpDisclaimer`, pinned on Today, Reports, Report detail, Plan and Chat |
| Disclaimer not dismissible on report and plan screens | `HpDisclaimer` has no dismiss affordance and no `onDismiss` parameter, anywhere. Tested. |
| Urgent findings dominate and cannot be swiped away | `HpEscalationCard`: full width, solid leading bar, square leading edge, the only solid alarm colour in the app, no close button, no `Dismissible`. Tested. |
| Never diagnose or prescribe | Every placeholder string; `test/safety_copy_test.dart` |
| Never guess a health number | `LabResult.value` is nullable, renders as `--`, and gets a "Type what your report says" action |
| Say where a threshold came from | `sourceCitation` shown on every result and on the escalation card |
| Consent states plainly what this is not, and that uploads go to Gemini | `ConsentScreen` — two separate switches, neither pre-ticked, version recorded |

## Accessibility

- **Contrast**: every text pair in both palettes is asserted at ≥ 4.5:1 and every
  interactive outline at ≥ 3:1 by `test/core/theme_test.dart`, which computes the WCAG
  ratio from the tokens themselves. Change a token badly and the build goes red.
- **Touch targets**: buttons are ≥ 52dp, text actions and choice pills ≥ 48dp. Tested.
- **Text scaling**: no fixed-height text containers; layouts use `Flexible`, `Wrap` and
  `IntrinsicHeight`. Tests render the escalation card and buttons at 2× scale.
- **Never colour alone**: every severity is an icon shape *plus* a word *plus* a
  colour; selection is a tick as well as a fill; "now" is a label as well as a dot.
- **Screen readers**: escalation cards are a live region; chips, meters and step
  indicators carry composed semantic labels rather than reading out fragments.

## Dependencies, and why each one is here

| Package | Why |
|---|---|
| `flutter_riverpod ^2.6.1` | State and dependency injection. **Classic `Notifier`/`Provider` API only** — the codegen variant is deliberately not used. |
| `go_router ^14.6.2` | Routing and the stateful five-tab shell, so each tab keeps its stack. |
| `http ^1.2.2` | Talking to our own FastAPI backend. Nothing else may hold a Gemini key. |
| `supabase_flutter ^2.8.0` | **Auth only.** Database access goes through the backend so RLS and the safety validator cannot be bypassed. |
| `flutter_secure_storage ^9.2.2` | The session token is the only secret on the device; it belongs in the Android Keystore. |
| `sqflite ^2.4.1`, `path ^1.9.0`, `path_provider ^2.1.5` | Offline cache of today's plan and recent values (`docs/02-architecture.md`). |
| `file_picker ^8.1.6`, `image_picker ^1.1.2` | Report upload: lab PDFs, photos of printed reports, food photos. |
| `flutter_local_notifications ^18.0.1`, `timezone ^0.9.4`, `flutter_timezone ^3.0.1` | Every alert in the product is time-based, so the phone schedules it itself and it works offline. This is the package that requires core library desugaring. |
| `fl_chart ^0.69.2` | Biomarker trend sparklines. |
| `intl ^0.19.0` | Dates, times and numbers, formatted in one place. |
| `shared_preferences ^2.3.4` | Small non-secret device preferences: last tab, units, onboarding completion. |

**Nothing that needs code generation.** No `build_runner`, `freezed`,
`json_serializable`, `riverpod_generator` or `drift`. Generated files cannot be produced
in the environment this code is authored in, and their absence is a build failure rather
than a warning, so every `fromJson`/`toJson` in `lib/data/models/` is written by hand and
covered by a round-trip test.

## Talking to the backend

### The seam

`HealthRepository` is the only thing the screens know about.
`FakeHealthRepository` and `HttpHealthRepository` implement exactly the same
interface, and `healthRepositoryProvider` picks between them on one condition:
is there an API address and did Supabase come up? Nothing else in the app
changes when the real service is switched on, and every widget test keeps
running against the fake.

### The cold start is real, and it is handled explicitly

The health engine runs on Render's free tier. A free instance is stopped after
about fifteen minutes without traffic and is started again by the first request
that arrives — which takes roughly **fifty seconds**. A twenty-second timeout
turns every first-open-of-the-day into a failure; a sixty-second timeout on
every request turns a genuinely broken network into a minute of staring.

So `ApiClient` tracks whether it believes the instance is up (a success inside
the last ten minutes). When it does not, it wakes the backend first with an
unauthenticated `GET /healthz` on a long timeout, retried once, before the real
request goes anywhere near the wire — and emits `ApiPhase.waking` if that takes
more than a couple of seconds, which is what puts *"Waking up the health
engine"* on Today instead of an unexplained spinner.

Waking with a probe rather than retrying the real request is deliberate.
Retrying a `POST /v1/chat/messages` that timed out can send the same message
twice, and the client cannot tell a request that never arrived from one that
arrived and answered slowly. A probe has no such problem. GETs and PUTs are
still replayed once if they time out after the probe succeeded; POSTs are not.
Report uploads are the one exception, because the backend hashes the file and
answers a duplicate from the stored extraction rather than reading it twice.

### Errors

The API answers every failure as RFC 9457 `application/problem+json`. The client
reads the `type`, matches it against `ApiFailureKind`, and shows **a sentence
this app wrote**. The server's own `detail` is kept for logs and never rendered:
it can change without the app knowing, a proxy can substitute its own body, and
a 500 detail is deliberately the same fixed sentence whatever happened.

### What the API does not have yet

Answered honestly rather than filled in on the client:

| Screen wants | Status |
|---|---|
| Day nutrient totals and ICMR targets | Not returned. Adding item nutrients up on the phone is exactly what the safety charter forbids, so they come back empty. |
| Goals, biomarker trends | No endpoint. Empty lists. |
| A report headline | Not returned by `GET /v1/reports/{id}`. Left null. |
| Hydration *logged* | No endpoint — the plan carries a target and nothing to count against it. The running total is kept on the phone, per day, and presented as the user's own tally. |
| A `lab_results` row id | `ResultOut` has none, so "confirm this value" cannot be wired to `POST /v1/reports/{id}/results/{result_id}/confirm` yet. |

## Reminders

Every alert is time-based, so the phone schedules it itself with Android's
`AlarmManager`. That is what makes them work with the app closed, with no
signal and with the backend asleep — which is the whole point of doing them
locally rather than with a push service.

`GET /v1/alerts` says *what* and *when*, with quiet hours already applied
server-side; `alert_schedule.dart` does the arithmetic (which calendar day, and
a second check of quiet hours in case the window changed offline) and
`notification_service.dart` hands the result to the plugin as daily repeating
`zonedSchedule` alarms in the device's own time zone. Wall-clock, not elapsed
time: a seven o'clock reminder is at seven o'clock on both sides of a
daylight-saving change, and `test/services/alert_schedule_test.dart` proves it
across a real spring-forward morning.

Escalation alerts are never silenced — not by quiet hours and not by switching
the type off. The server refuses to disable them and the device honours the same
rule.

Permission is requested **when there is a plan on screen with times on it**, not
on first launch. Asking before somebody has any reason to want a reminder is how
an app earns a permanent refusal.

## Offline

`sqflite` keeps three things: today's briefing, the latest report's summary line
and the alert definitions. Anything served from it is labelled with
`HpStaleNotice` — *"Saved on this phone — last updated 2 hours ago"* — and
never presented as current.

Two things are deliberately **not** cached:

- **Escalations.** A red flag is a statement about somebody's health *now*.
  Serving a stored one after a failed refresh would show a finding that may
  already have been resolved and hide a new one nobody fetched. They are
  stripped before the briefing is written, and the offline banner says plainly
  that nothing new was checked.
- **Report values.** The report screen is never answered from the cache at all.

## Known risks

This code has never been compiled. CI is its first compiler, and these are the places to
look first if it goes red:

1. **`ndkVersion` is pinned to `27.0.12077973`** in `android/app/build.gradle`, because
   several plugins declare NDK 27 and AGP 8.7 fails when the app module asks for an
   older one. If the runner's SDK does not have that NDK, swap it for
   `flutter.ndkVersion` and see which error you prefer.
2. **`fl_chart` 0.69** — `RangeAnnotations` and `HorizontalRangeAnnotation` in
   `lib/features/reports/trend_sparkline.dart` are the least-stable API surface used
   anywhere in the app. If the chart will not compile, delete the `rangeAnnotations:`
   argument; nothing else depends on it.
3. **`intl ^0.19.0`** — if a future Flutter stable pulls `flutter_localizations` into the
   resolution and demands `intl 0.20`, relax this constraint.
4. **Bundled fonts** — seven static TrueType files verified by header and name table but
   never rendered. If text falls back to the system font, the fault is in the `fonts:`
   block of `pubspec.yaml`, not in the files.
5. **`flutter_local_notifications` 18.0.1** — `zonedSchedule` in this version
   still requires *both* `uiLocalNotificationDateInterpretation` and
   `androidScheduleMode`. The former is only removed in 19.0.0. If the
   constraint is ever relaxed past `^18`, that argument has to go.
6. **`supabase_flutter` 2.8** — `auth_service.dart` deliberately leans on type
   inference around `onAuthStateChange` and `currentSession` so that a renamed
   type in a patch release is not a compile error here.
7. **`supabase_flutter`'s `anonKey`** — `^2.8.0` resolves to the newest 2.x,
   and later 2.x releases mark `Supabase.initialize(anonKey:)` deprecated in
   favour of `publishableKey`. It still exists and still works, so this is an
   analyzer *info* rather than a failure (`flutter analyze --no-fatal-infos`).
   If it is ever removed, `core/bootstrap.dart` is the only place to change.
