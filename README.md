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

## Difficulty scaling

The SpriteKit sports games (AFL, Rugby) get harder as your score climbs — several levers
ramp together, all score-driven. The table below is for **Rugby**, which uses every lever.
**AFL** is identical except it has **no speed ramp** (defenders hold a constant ~400) and
all scaling plateaus at score **66**, so AFL teammates cap at **5**.

Both games' defenders start **slower than the player** (400 vs the player's 480); in Rugby
the speed ramp catches them up (matching the player around score 80) and past.

| Score | Defenders (chasers + back line) | Teammates | Carrier pressure | Defender speed |
|------:|:--------------------------------|:---------:|:-----------------|:---------------|
| 0–5    | 4 (4 + 0)          | 3 | 1 engages the carrier; 1 outlet left open; widest containment ring | 400 |
| 6–29   | 5 → 8 (+1 / 6 pts) | 3 | same as above | 400 |
| 30–35  | 9 (9 + 0)          | 4 | aggression starts climbing → ring tightening | 400 |
| 36–41  | 10 (10 + 0)        | 4 | ring tightening | 400 |
| 42–44  | 11 (10 + **1**)    | 4 | back line appears; still 1 engager | 400 |
| 45–47  | 11 (10 + 1)        | 4 | **2 defenders** engage the carrier | 400 |
| 48–53  | 12 (10 + **2**)    | 4 | **every outlet marked** | 400 |
| 54–59  | 13 (10 + **3**)    | 4 | ring near tightest | 400 |
| 60–65  | 14 (10 + **4**)    | 5 | tightest ring; aggression maxed | 400, then **+4 / pt** from 61 |
| 66–89  | 15 (10 + **5**)    | 5 | max pressure | ramping |
| 90–119 | 15                 | 6 | max pressure | ramping |
| 120–149| 15                 | 7 | max pressure | ramping |
| 150+   | 15                 | 8 | max pressure | **760** (capped) |

**Milestones:** back line from score 42, second engager at 45, all outlets marked from 48,
peak aggression + speed ramp at 60–61, full 15 defenders from 66, top speed from 150.
Teammates start at 3 and gain one every 30 points — 4 (30) → 5 (60) → 6 (90) → 7 (120) →
8 (150) — capped at each game's difficulty plateau (AFL 5, Rugby 8).

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
