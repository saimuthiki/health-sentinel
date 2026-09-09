# Steps only you can do

Written for someone new to this. Do them in order. **You never need to send me a password or
key — you type secrets directly into the website that needs them.**

---

## M0 · Replace your Gemini key  ⚠️ do this first

You pasted your key into a chat, so treat it as public.

1. Open **aistudio.google.com** and sign in.
2. Click **Get API key** (top left).
3. Find the key you have been using, click the **⋮** menu, choose **Delete**.
4. Click **Create API key** → choose your project → **Create**.
5. Copy the new key into a password manager or a note only you can see.
6. **Do not paste it to me and do not put it in the repo.** You will paste it into Render in
   step M3.

---

## M1 · Create the Supabase project

1. Go to **supabase.com** → **Start your project** → sign in with GitHub.
2. **New project**. Name: `healthpulse`. Choose a strong database password and save it.
3. Region: **Mumbai (ap-south-1)** — closest to you, so the app feels faster.
4. Wait ~2 minutes for it to build.
5. Go to **Project Settings → API**. You will see three things:
   - **Project URL** — safe to share, goes in the app config.
   - **anon / public key** — safe to ship in the app.
   - **service_role key** — 🔴 **secret**. Never in the app, never in the repo, never in
     chat. Only into Render in step M3.
6. Tell me the **Project URL** and **anon key** — those two only.

---

## M2 · Turn on the sign-in methods

In Supabase → **Authentication → Providers**:
1. **Email** — already on. Turn **off** "Confirm email" while developing so you can test
   quickly, and turn it back on before release.
2. **Google** (optional, nicer login) — needs a Google OAuth client. Skip for now; we can add
   it in Phase 9.

---

## M3 · Create the backend service on Render

1. Go to **render.com** → sign up with GitHub.
2. **New → Web Service** → connect `saimuthiki/health-sentinel`.
3. Settings:
   - **Root directory**: `backend`
   - **Runtime**: Python 3
   - **Build command**: `pip install -r requirements.txt`
   - **Start command**: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
   - **Instance type**: **Free**
4. Open **Environment** and add these (click *Add Environment Variable* for each):

   | Key | Value |
   |---|---|
   | `GEMINI_API_KEY` | your **new** key from M0 |
   | `SUPABASE_URL` | Project URL from M1 |
   | `SUPABASE_SERVICE_ROLE_KEY` | the 🔴 service_role key from M1 |
   | `SUPABASE_JWT_SECRET` | Supabase → Settings → API → JWT Secret |
   | `ENVIRONMENT` | `development` |

5. **Create Web Service.** Copy the URL it gives you (like
   `https://healthpulse-api.onrender.com`) and send it to me — that is not a secret.

> The free plan sleeps after 15 minutes of no traffic and takes ~50 seconds to wake. The app
> shows a "waking up" message. We move to Google Cloud Run before public launch.

---

## M4 · Apply the database schema

Once I have pushed `db/migrations/`:
1. Supabase → **SQL Editor** → **New query**.
2. Open each file in `db/migrations/` **in number order**, paste, click **Run**.
3. Then run every file in `db/policies/`, then `db/seed/`.
4. Go to **Table Editor** and check the tables are there.

I will give you the exact list and order in a `db/README.md`.

---

## M5 · Install the build tools (optional)

Only if you want to run the app on your own PC. **You can skip all of this** — GitHub
Actions builds the APK for you.

1. **Android Studio** — developer.android.com/studio. During setup accept *Android SDK*,
   *SDK Command-line Tools*, *Platform-Tools*.
2. **Flutter SDK** — docs.flutter.dev/get-started/install → download the zip → extract to
   `C:\src\flutter` → add `C:\src\flutter\bin` to your PATH.
3. Open a new terminal, run `flutter doctor`. Then `flutter doctor --android-licenses` and
   press `y` to everything.
4. You are done when *Flutter* and *Android toolchain* both show a green tick.

---

## M6 · Nutrition data (I need your help fetching one file)

- **USDA FoodData Central** — I can pull this automatically with a free API key. Get one at
  `fdc.nal.usda.gov/api-key-signup.html` and put it in Render as `USDA_API_KEY`.
- **IFCT 2017** (Indian Food Composition Tables, National Institute of Nutrition) — the
  authoritative source for Indian foods. It is published as a book/PDF and is not on a
  clean API. If you can download the data file, drop it in `db/seed/sources/`. Otherwise I
  will seed ~250 common Indian foods from USDA plus published IFCT values with citations,
  which is enough to start.

---

## M7 · App signing key

Needed once, before any release build. Run this on your PC after M5 (or tell me and I will
add a CI step that generates it):

```
keytool -genkey -v -keystore upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

It asks for a password and some details (name, city, country — any real values are fine).
Then:
1. Run `certutil -encode upload.jks upload.txt` (Windows) or `base64 upload.jks` (Mac/Linux).
2. In GitHub → your repo → **Settings → Secrets and variables → Actions → New repository
   secret**, add:
   - `KEYSTORE_BASE64` — the text from step 1
   - `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS` (`upload`)
3. **Back up `upload.jks` somewhere safe.** If you lose it you can never update the app on
   the Play Store.

---

## M8 · Privacy policy URL (needed for Play Store)

The Play Store requires a public web page. Free option: I write the policy as Markdown in
the repo, you enable **GitHub Pages** (repo → Settings → Pages → source `main`, folder
`/docs`) and the URL becomes
`https://saimuthiki.github.io/health-sentinel/privacy`.

---

## M9 · Google Play Console (only when you want to publish)

- **$25 one-time**, at `play.google.com/console`.
- New personal developer accounts must run a **closed test with at least 12 testers for 14
  continuous days** before production access. Start recruiting testers early — this is the
  slowest part of launching, not the code.
- You will complete: Health Apps declaration, Data safety form, privacy policy URL, content
  rating, target audience.
- **None of this blocks you using the app yourself** — the sideloaded APK works from Phase 1.

---

## M10 · Your phone

1. Android **8.0 or newer** — tell me your version.
2. Allow **install from unknown sources** for your browser or file manager.
3. After installing: Settings → Apps → HealthPulse → **Battery → Unrestricted**. Without
   this, Android will silently kill your reminders. This is the number one reason health
   reminder apps stop working.
4. Allow **Notifications** and **Alarms & reminders** when the app asks.

---

## M11 · Things I need from you for quality (not blocking)

1. **One or two of your own lab reports** (PDF or photo). Put them in `samples/` in the repo,
   or paste the text. Redact your name if you like — I need the layout, not your identity.
   Real Indian lab formats vary a lot and this is what makes extraction accurate.
2. **Your profile**: age, sex, height, weight, activity level, any conditions, allergies.
3. **Food**: veg / non-veg / egg, cuisine you actually eat, five foods you love, five you
   refuse.
4. **Your day**: wake time, sleep time, usual meal times, exercise days.
5. **Your goals**, in your words.
6. The **Gemini prompt template** you mentioned having, and any parsing code you wrote.
