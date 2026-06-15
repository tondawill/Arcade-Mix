# Supabase Setup Checklist

The Supabase integration is **already written** — `SupabaseAuthService`,
`SupabaseHighScoreService`, and `SupabaseClientProvider` live in `Backend/`, all behind
`#if canImport(Supabase)`. The app currently runs on on-device Local services; it
**automatically switches to Supabase** once (a) the package is added and (b) the
credentials are present. `BackendProvider.resolveServices()` does the switch — no code
edits needed.

Do these steps to go live:

## 1. Add the Swift Package

In Xcode:

1. **File → Add Package Dependencies…**
2. Enter the URL: `https://github.com/supabase/supabase-swift`
3. Dependency rule: **Up to Next Major Version** (e.g. `2.0.0`).
4. Add the **`Supabase`** product to the **Arcade Mix** target.

> CLI alternative (if you later convert to a Package.swift / Tuist setup):
> `.package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0")`

## 2. Store credentials (do NOT hardcode)

**This is already wired up.** The plumbing exists:

- `Config/Secrets.xcconfig` (git-ignored) — a build config assigned to both the
  Debug and Release configurations of the target.
- `Arcade Mix/Info.plist` exposes `SUPABASE_HOST` / `SUPABASE_ANON_KEY` via
  `$(...)` build-setting substitution.
- `Arcade Mix/Backend/AppSecrets.swift` reads those values safely (returns `nil`
  while they're still placeholders, so the app keeps running on mocks).

You only need to **fill in the two values** in `Config/Secrets.xcconfig`, taken
from the Supabase dashboard (Project Settings → API):

```
SUPABASE_HOST = your-project-ref.supabase.co   # the Project URL WITHOUT https://
SUPABASE_ANON_KEY = your-anon-public-key        # the "anon"/"public" key, never service_role
```

> We store the host without `https://` because `.xcconfig` treats `//` as a
> comment; `AppSecrets.supabaseURL` re-adds the scheme.

`Config/Secrets.xcconfig` is already in `.gitignore`; commit
`Config/Secrets.example.xcconfig` as the template for other machines.

## 3. Enable Sign in with Apple

The app gates on login and offers **Sign in with Apple** (primary) + email/password
(fallback). For Apple to work:

- **Capability / entitlement**: `Arcade Mix/Arcade Mix.entitlements` already declares
  `com.apple.developer.applesignin`. In Xcode, confirm the target's **Signing &
  Capabilities** shows "Sign in with Apple" (with automatic signing + your team it
  should register on the App ID automatically). On the iOS **Simulator** you can test
  with a signed-in Apple Account; on device the App ID must have the capability.
- **Supabase dashboard → Authentication → Providers → Apple**: enable it. For native
  (id-token) sign-in, add the app's **bundle id** `tonda.Arcade-Mix` to the list of
  authorized client IDs. (No redirect URL is needed for the native token flow.)
- **Supabase dashboard → Authentication → Providers → Email**: enable it for the
  fallback (turn off "Confirm email" during development if you want instant sign-up).

> Before Supabase is configured, the email fallback still works locally (it creates a
> persisted on-device user), so you're never blocked while testing.

## 4. The provider switches itself

No code change. `BackendProvider` calls `SupabaseClientProvider.shared`, which builds a
`SupabaseClient` only when `AppSecrets` has real values. With the package added + creds
set, the app uses `SupabaseAuthService` / `SupabaseHighScoreService`; otherwise it uses
the Local services. (`HighScore` already has snake_case `CodingKeys`, so rows decode
directly.)

## 5. Database schema (run the migrations)

The SQL lives in `~/Supabase/migrations/`. Open each file and paste it into the
Supabase **SQL editor**, **in numeric order**:

| Order | File | What it does |
|-------|------|--------------|
| 1 | `0001_create_high_scores_table.sql` | Creates `public.high_scores`. |
| 2 | `0002_high_scores_row_level_security.sql` | Enables RLS: public read, insert-own-only. |
| 3 | `0003_high_scores_leaderboard_index.sql` | Index for fast per-game top-scores. |

The scripts are idempotent (`if not exists` / `drop policy if exists`), so re-running
them is safe.

> `HighScore` already maps its Swift properties to the snake_case columns via
> `CodingKeys`, and `HighScoreInsert` posts `game_id/user_id/display_name/score` (the DB
> fills `id`/`created_at`). The RLS insert policy (`auth.uid() = user_id`) is satisfied
> automatically because submissions run on the signed-in session.
