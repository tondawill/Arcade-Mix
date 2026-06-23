//
//  BrickBreakerConfig.swift
//  Arcade Mix
//
//  Data-only tuning + shared enums for Brick Breaker, mirroring the SportConfig
//  pattern: numbers / sizes / colors live here, while behavior lives in
//  `BrickBreakerScene`. Brick Breaker is a standalone arcade game (it does NOT use
//  the sport `BaseGameScene`), so it owns its own physics categories and state enum.
//

import SpriteKit

/// Bit masks for SpriteKit contact detection. The ball is the only moving body that
/// reports contacts; everything else is static.
enum BBPhysicsCategory {
    static let none: UInt32   = 0
    static let ball: UInt32   = 1 << 0
    static let paddle: UInt32 = 1 << 1
    static let brick: UInt32  = 1 << 2
    static let wall: UInt32   = 1 << 3
    static let powerUp: UInt32 = 1 << 4
}

/// Game phases. `.serving` parks the ball on the paddle until the player launches it;
/// `.playing` is live; `.levelCleared` is the brief beat before the next layout.
enum BrickBreakerState {
    case serving, playing, levelCleared, gameOver
}

/// A brick's colour. The flood-fill colour-chain only links bricks of the *exact*
/// same colour, so this is a first-class property (not just a render tint).
enum BrickColor: CaseIterable {
    case red, blue, green, yellow

    var fill: SKColor {
        switch self {
        case .red:    return SKColor(red: 0.90, green: 0.25, blue: 0.25, alpha: 1)
        case .blue:   return SKColor(red: 0.25, green: 0.50, blue: 0.95, alpha: 1)
        case .green:  return SKColor(red: 0.25, green: 0.78, blue: 0.40, alpha: 1)
        case .yellow: return SKColor(red: 0.95, green: 0.80, blue: 0.25, alpha: 1)
        }
    }
}

/// What kind of brick sits in a grid slot.
/// - `basic`: 1 hit, participates in the colour-chain.
/// - `strong`: multiple hits, changes colour state per hit (does not chain).
/// - `titanium`: indestructible; ignored when checking "level cleared".
/// - `hazard`: 1 hit, but spawns a Red Field slow-zone when destroyed.
/// - `powerup`: 1 hit, drops a falling power-up token when destroyed.
enum BrickType {
    case basic, strong, titanium, hazard, powerup
}

/// Power-ups a `powerup` brick can drop. `chain` is required by the brief (it arms the
/// colour-chain reaction); the rest are classic temporary boons.
enum PowerUpKind: CaseIterable {
    case chain, multiBall, widePaddle, slowBall

    /// Token colour so the player can read what's falling at a glance.
    var color: SKColor {
        switch self {
        case .chain:      return SKColor(red: 1.0, green: 0.45, blue: 0.85, alpha: 1)  // magenta
        case .multiBall:  return SKColor(red: 1.0, green: 0.85, blue: 0.20, alpha: 1)  // gold
        case .widePaddle: return SKColor(red: 0.30, green: 0.85, blue: 0.95, alpha: 1) // cyan
        case .slowBall:   return SKColor(red: 0.65, green: 0.55, blue: 1.0, alpha: 1)  // violet
        }
    }

    /// Single-letter glyph drawn on the token (placeholder — no sprites yet).
    var glyph: String {
        switch self {
        case .chain:      return "C"
        case .multiBall:  return "M"
        case .widePaddle: return "W"
        case .slowBall:   return "S"
        }
    }
}

/// Per-game tuning. Pure data; all behavior is in `BrickBreakerScene`.
struct BrickBreakerConfig {

    // Lives
    var startingLives: Int

    // Paddle
    var paddleSize: CGSize
    var paddleBottomInset: CGFloat   // gap from the bottom safe edge up to the paddle
    var widePaddleScale: CGFloat     // width multiplier while the Wide power-up is active

    // Ball
    var ballRadius: CGFloat
    var ballSpeed: CGFloat           // constant baseline magnitude (points / second)
    var maxBounceAngle: CGFloat      // steepest rebound off a paddle edge, from vertical
    var slowBallFactor: CGFloat      // baseline-speed multiplier while Slow is active

    // Brick grid
    var columns: Int
    var brickHeight: CGFloat
    var brickGap: CGFloat
    var gridTopInset: CGFloat        // gap from the top safe edge down to the first row
    var sideInset: CGFloat           // left/right play-area margin (also clamps the paddle)
    var maxRows: Int

    // Field safety (kept clear of the home indicator / notch)
    var topSafeInset: CGFloat
    var bottomSafeInset: CGFloat

    // Crunch ("Decline & Crunch")
    var crunchInterval: TimeInterval // seconds between brick-container descents
    var crunchActivationFactor: CGFloat  // crunch only runs once difficultyFactor exceeds this

    // Hazard
    var redFieldDuration: TimeInterval   // how long a Red Field lingers before fading
    var redFieldDamp: CGFloat            // speed multiplier while a ball is inside a field

    // Power-up timings
    var chainDuration: TimeInterval
    var widePaddleDuration: TimeInterval
    var slowBallDuration: TimeInterval

    // Colors
    var backgroundColor: SKColor
    var paddleColor: SKColor
    var ballColor: SKColor
    var strongColor: SKColor         // tint overlaid on a strong brick (darkens per hit)
    var titaniumColor: SKColor
    var hazardColor: SKColor         // dark red, distinct from a basic red brick
    var powerupBrickColor: SKColor
    var redFieldColor: SKColor

    /// Cell width derived from the play area so the grid always spans it evenly.
    func brickWidth(forSceneWidth width: CGFloat) -> CGFloat {
        let usable = width - 2 * sideInset - CGFloat(columns - 1) * brickGap
        return usable / CGFloat(columns)
    }
}

extension BrickBreakerConfig {
    /// Portrait preset tuned for iPhone SE (320×568 pt). The scene is created at this
    /// size and scaled with `.resizeFill`.
    static let `default` = BrickBreakerConfig(
        startingLives: 3,
        paddleSize: CGSize(width: 92, height: 16),
        paddleBottomInset: 24,
        widePaddleScale: 1.6,
        ballRadius: 8,
        ballSpeed: 320,
        maxBounceAngle: .pi / 3,        // 60° off vertical at the very edge
        slowBallFactor: 0.5,
        columns: 7,
        brickHeight: 22,
        brickGap: 4,
        gridTopInset: 40,
        sideInset: 14,
        maxRows: 9,
        topSafeInset: 50,
        bottomSafeInset: 24,
        crunchInterval: 20,
        crunchActivationFactor: 0.5,
        redFieldDuration: 4,
        redFieldDamp: 0.5,
        chainDuration: 12,
        widePaddleDuration: 12,
        slowBallDuration: 10,
        backgroundColor: SKColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1),
        paddleColor: SKColor(red: 0.85, green: 0.90, blue: 1.0, alpha: 1),
        ballColor: SKColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 1),
        strongColor: SKColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1),
        titaniumColor: SKColor(red: 0.40, green: 0.42, blue: 0.48, alpha: 1),
        hazardColor: SKColor(red: 0.45, green: 0.06, blue: 0.06, alpha: 1),
        powerupBrickColor: SKColor(red: 0.80, green: 0.35, blue: 0.85, alpha: 1),
        redFieldColor: SKColor(red: 0.95, green: 0.15, blue: 0.15, alpha: 0.30)
    )
}
