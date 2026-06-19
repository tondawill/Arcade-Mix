//
//  SportConfig.swift
//  Arcade Mix
//
//  Data-only tuning for a `BaseGameScene` sport. Each game supplies a `SportConfig`
//  (numbers, sizes, colors) while sport-specific *behavior* lives in `BaseGameScene`
//  hook overrides. Keeps the shared engine free of per-sport magic numbers.
//

import SpriteKit

/// Bit masks for SpriteKit physics contact detection (a backup to the distance-based
/// gameplay checks in `BaseGameScene`, which run while nodes are moved by position).
enum PhysicsCategory {
    static let none: UInt32      = 0
    static let ball: UInt32      = 1 << 0
    static let player: UInt32    = 1 << 1
    static let teammate: UInt32  = 1 << 2
    static let opponent: UInt32  = 1 << 3
    static let goalZone: UInt32  = 1 << 4
    static let ground: UInt32    = 1 << 5
}

/// Shared phases for every sport scene. `.aerial` = ball in flight from the kick-off;
/// `.kicking` = the staged set-piece kick (AFL set shot / Rugby conversion);
/// `.paused` = play frozen waiting for the player to lift and re-press to restart
/// (e.g. Rugby's play-the-ball after a tackle).
enum GameState {
    case aerial, playOn, passing, kicking, paused, gameOver
}

/// Per-sport tuning. Behavior differences are overridden methods on `BaseGameScene`;
/// everything here is plain data.
struct SportConfig {

    // Field & geometry
    var fieldSize: CGSize
    var scoringLineX: CGFloat        // forward-50 (AFL) / try line (Rugby)
    var margin: CGFloat

    // Movement speeds
    var playerSpeed: CGFloat        // teammates also run at this pace (keep up with the carrier)
    var opponentSpeed: CGFloat
    var teammateLeadAhead: CGFloat
    var teammateLineBuffer: CGFloat  // stay this far short of the scoring line
    var teammateOpenRadius: CGFloat
    var teammateSpread: CGFloat
    var handpassSpeed: CGFloat
    var kickoffSpeed: CGFloat        // horizontal pace of the kicked-in ball

    // Sizes
    var playerSide: CGFloat
    var ballRadius: CGFloat

    // Aerial flight visuals
    var aerialArcHeight: CGFloat
    var minFlightScale: CGFloat
    var maxFlightScale: CGFloat
    var catchWindowStart: CGFloat

    // Camera
    var worldVisibleHeight: CGFloat
    var setShotVisibleHeight: CGFloat

    // Detection radii
    var markRadius: CGFloat
    var pickupRadius: CGFloat
    var tackleRadius: CGFloat
    var interceptRadius: CGFloat
    var arriveRadius: CGFloat
    var passTapRadius: CGFloat

    // Defenders
    var startingDefenders: Int
    var maxDefenders: Int           // total cap (chasers + back-line defenders)
    var maxChasers: Int             // of the total, how many press/mark; the rest hold the line
    var surroundRadiusBase: CGFloat
    var surroundRadiusMin: CGFloat
    var markGoalSideOffset: CGFloat
    var opponentSeparation: CGFloat
    var minCarrierDefenders: Int

    // Colors
    var grassColor: SKColor
    var groundColor: SKColor
    var friendlyColor: SKColor
    var activeColor: SKColor
    var opponentColor: SKColor
    var ballColor: SKColor
}

extension SportConfig {
    /// AFL preset — values identical to the original `AFLGameScene` constants so the
    /// refactor is behavior-preserving.
    static let afl = SportConfig(
        fieldSize: CGSize(width: 2800, height: 1400),
        scoringLineX: 2100,
        margin: 120,
        playerSpeed: 480,
        opponentSpeed: 400,
        teammateLeadAhead: 280,
        teammateLineBuffer: 120,
        teammateOpenRadius: 220,
        teammateSpread: 200,
        handpassSpeed: 1500,
        kickoffSpeed: 760,
        playerSide: 60,
        ballRadius: 22,
        aerialArcHeight: 360,
        minFlightScale: 0.45,
        maxFlightScale: 1.8,
        catchWindowStart: 0.85,
        worldVisibleHeight: 1500,
        setShotVisibleHeight: 1500,
        markRadius: 95,
        pickupRadius: 64,
        tackleRadius: 62,
        interceptRadius: 54,
        arriveRadius: 52,
        passTapRadius: 200,
        startingDefenders: 4,
        maxDefenders: 15,
        maxChasers: 10,
        surroundRadiusBase: 150,
        surroundRadiusMin: 110,
        markGoalSideOffset: 46,
        opponentSeparation: 80,
        minCarrierDefenders: 3,
        grassColor: SKColor(red: 0.18, green: 0.42, blue: 0.20, alpha: 1),
        groundColor: SKColor(red: 0.22, green: 0.5, blue: 0.24, alpha: 1),
        friendlyColor: SKColor(red: 0.20, green: 0.75, blue: 0.30, alpha: 1),
        activeColor: SKColor(red: 0.45, green: 1.0, blue: 0.50, alpha: 1),
        opponentColor: SKColor(red: 0.85, green: 0.18, blue: 0.18, alpha: 1),
        ballColor: SKColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1)
    )

    /// Rugby League preset. Mirrors AFL's field/AI tuning but moves the scoring line to
    /// the very end of the pitch (the try line) and uses a distinct blue strip so the
    /// two games read differently.
    static let rugby = SportConfig(
        fieldSize: CGSize(width: 2800, height: 1400),
        scoringLineX: 2650,                 // try line at the very end (posts sit at the edge)
        margin: 120,
        playerSpeed: 480,
        opponentSpeed: 400,                 // start slower than the player (480); the speed ramp catches them up
        teammateLeadAhead: 280,
        teammateLineBuffer: 120,
        teammateOpenRadius: 220,
        teammateSpread: 200,
        handpassSpeed: 1500,
        kickoffSpeed: 1300,                 // fast kick-in flight (lands around halfway)
        playerSide: 60,
        ballRadius: 22,
        aerialArcHeight: 360,
        minFlightScale: 0.45,
        maxFlightScale: 1.8,
        catchWindowStart: 0.85,
        worldVisibleHeight: 1500,
        setShotVisibleHeight: 1500,
        markRadius: 95,
        pickupRadius: 64,
        tackleRadius: 62,
        interceptRadius: 54,
        arriveRadius: 52,
        passTapRadius: 200,
        startingDefenders: 4,
        maxDefenders: 15,
        maxChasers: 10,
        surroundRadiusBase: 150,
        surroundRadiusMin: 110,
        markGoalSideOffset: 46,
        opponentSeparation: 80,
        minCarrierDefenders: 3,
        grassColor: SKColor(red: 0.18, green: 0.42, blue: 0.20, alpha: 1),
        groundColor: SKColor(red: 0.22, green: 0.5, blue: 0.24, alpha: 1),
        friendlyColor: SKColor(red: 0.20, green: 0.45, blue: 0.88, alpha: 1),
        activeColor: SKColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1),
        opponentColor: SKColor(red: 0.85, green: 0.18, blue: 0.18, alpha: 1),
        ballColor: SKColor(red: 0.80, green: 0.52, blue: 0.20, alpha: 1)
    )
}
