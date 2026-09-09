# Open decisions

Answer these and I will lock them into the design. My recommendation is first in each list.

### D1 · Product name
Repo stays `health-sentinel`; the app's display name can differ.
- **HealthPulse** *(recommended — from your list, cleanest, reads as coaching not diagnosis)*
- MyHealth AI · HealthMate AI *(both are heavily used on the Play Store already)*

⚠️ Whatever you pick, search the Play Store and a trademark register before you print it on
an icon. Name collisions are a common reason listings get rejected.

### D2 · Database — Supabase or Firebase
- **Supabase** *(recommended — see `02-architecture.md` §3: your schema is relational, RLS
  gives real per-user isolation, storage is on the free tier)*
- Firebase — better Flutter tooling and FCM built in, but document-store friction and
  Storage now wants a billing account on new projects.

### D3 · Push notifications
- **Device-local notifications only for now** *(recommended — covers every time-based alert
  you listed, needs no server, works offline; add FCM in Phase 7)*
- Firebase Cloud Messaging from day one.

### D4 · Backend host
- **Render free** *(recommended to start — no card, 50 s cold start)*
- Google Cloud Run *(better, needs a card on file even though you stay free)*

### D5 · Multi-user from day one, or single-user first?
- **Multi-user with real auth from day one** *(recommended — you want a public app, and
  retrofitting auth and per-user isolation later is painful and risky with health data)*
- Single-user POC first, add auth later.

### D6 · Food database focus
- **Indian foods first (IFCT + USDA), English UI** *(recommended)*
- Global/generic first.

### D7 · iOS
- **Android only for now, keep the code iOS-clean** *(recommended — an Apple developer
  account is $99/year and you cannot build iOS without a Mac)*
- Plan for iOS in Phase 9.

### D8 · Signing
- **Generate a proper upload keystore now (M7)** *(recommended — five minutes, and required
  for the Play Store later)*
- Debug-signed release APKs for now; add the keystore before release.
