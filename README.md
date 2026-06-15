# Arcade Mix

A multi-game arcade hub for iOS, built with **Swift**, **SwiftUI**, and **SpriteKit**.
The first game is a high-energy **AFL arcade** game; more games (e.g. PvP Connect 4)
are planned.

## Features

- **Modular multi-game hub** — a SwiftUI menu of game tiles; the active game view/scene
  is swapped from a single source of truth (`GameInfo.catalog`).
- **Full localization** — English & Czech via a String Catalog (`Localizable.xcstrings`);
  no hardcoded UI strings.
- **AFL arcade game** — state machine (aerial → mark / scramble → handpass → set shot),
  joystick + keyboard movement, tap-to-handpass, swipe-to-kick scoring.
- **Global high scores** — shown on each hub tile, backed by Supabase (with an on-device
  fallback so the app runs with zero setup).
- **Auth** — Sign in with Apple (primary) + email/password (fallback).

## Requirements

- Xcode 26.5+ / iOS 26.5 SDK
- The **Supabase Swift** package (added via Swift Package Manager) — optional; the app
  runs on local storage until it's configured.

## Getting started

1. Open `Arcade Mix.xcodeproj` in Xcode.
2. Build & run on an iPhone simulator. The app works immediately using on-device
   (local) auth and high scores — no backend required.

### Enabling Supabase (optional, for the global leaderboard)

Credentials are read from `Config/Secrets.xcconfig`, which is **git-ignored**. To set up:

1. Copy the template:
   ```sh
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```
2. Fill in your Supabase host + anon key.
3. Follow the full guide in [`Arcade Mix/Backend/SUPABASE_SETUP.md`](Arcade%20Mix/Backend/SUPABASE_SETUP.md),
   including the SQL migrations in `~/Supabase/migrations/` and enabling the Apple/Email
   auth providers.

The Supabase code is guarded by `#if canImport(Supabase)`, so the project compiles and
runs whether or not the package and credentials are present.

## Project layout

```
Arcade Mix/
  App/        App entry, navigation coordinator, orientation lock
  Models/     Game catalog (GameInfo)
  Hub/        Main menu + game tiles (with high scores)
  Auth/       Login screen + Sign in with Apple
  Games/AFL/  AFL SpriteKit scene + SwiftUI host
  Backend/    Auth & high-score services (local + Supabase), models, setup docs
  Resources/  Localizable.xcstrings (en, cs)
Config/       Secrets.example.xcconfig (template; real Secrets.xcconfig is git-ignored)
```
