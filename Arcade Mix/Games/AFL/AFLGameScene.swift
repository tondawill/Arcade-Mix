//
//  AFLGameScene.swift
//  Arcade Mix
//
//  Playable AFL arcade prototype with placeholder art:
//    • friendlies  = green squares (the active one is highlighted)
//    • opponents   = red squares
//    • ball        = orange circle
//
//  Flow:  .aerial → (Mark) .setShot   |   .aerial → (miss) .playOn
//         .playOn → (handpass) .passing → (caught) .playOn (control switches)
//         .playOn → (cross Forward 50) .setShot → (swipe kick) score → .aerial
//
//  Control model: virtual joystick to move the active player; tapping a teammate
//  triggers the handpass.
//

import SpriteKit
import GameplayKit
import UIKit

/// Bit masks for SpriteKit physics contact detection (kept as a backup; gameplay
/// detection below is primarily distance-based for determinism while nodes are
/// moved by position each frame).
enum PhysicsCategory {
    static let none: UInt32      = 0
    static let ball: UInt32      = 1 << 0
    static let player: UInt32    = 1 << 1
    static let teammate: UInt32  = 1 << 2
    static let opponent: UInt32  = 1 << 3
    static let goalZone: UInt32  = 1 << 4
    static let ground: UInt32    = 1 << 5
}

final class AFLGameScene: SKScene {

    // MARK: - Tunable constants

    private let fieldSize = CGSize(width: 2800, height: 1400)
    private let forward50X: CGFloat = 2100
    private let playerSpeed: CGFloat = 480
    private let opponentSpeed: CGFloat = 400
    private let teammateSpeed: CGFloat = 380         // a touch slower than the carrier
    private let teammateLeadAhead: CGFloat = 280     // how far ahead of the carrier they run
    private let teammateF50Buffer: CGFloat = 120     // stay short of the 50 so a pass isn't an instant set shot
    private let teammateOpenRadius: CGFloat = 220    // peel away from defenders within this range
    private let teammateSpread: CGFloat = 200        // vertical gap between teammate lanes
    private let handpassSpeed: CGFloat = 1500
    private let aerialSpeed: CGFloat = 760
    private let playerSide: CGFloat = 60
    private let ballRadius: CGFloat = 22
    private let worldVisibleHeight: CGFloat = 1500
    private let margin: CGFloat = 120          // keep spawns inside the boundary

    // Detection radii.
    private let markRadius: CGFloat = 95
    private let pickupRadius: CGFloat = 64
    private let tackleRadius: CGFloat = 62
    private let interceptRadius: CGFloat = 54
    private let arriveRadius: CGFloat = 52
    private let passTapRadius: CGFloat = 200    // forgiving tap target for picking a teammate to pass to

    // Defenders.
    private let startingDefenders = 4
    private let maxDefenders = 10               // keep gaps passable as the count scales

    // Set-shot staging (a clean area of the world, above the field).
    private var stageCenter: CGPoint { CGPoint(x: fieldSize.width / 2, y: fieldSize.height + 1600) }
    private var stageBall: CGPoint { CGPoint(x: stageCenter.x, y: stageCenter.y - 500) }
    private var stagePostLineY: CGFloat { stageCenter.y + 420 }
    private var goalBallY: CGFloat { stagePostLineY + 120 }   // set-shot balls arrive high in the goal
    private let setShotVisibleHeight: CGFloat = 1500

    // Goalkeeper on the set shot. He rests on the ground and LEAPS up to the ball's height
    // to catch it — shoot when he's down.
    private let keeperHalfWidth: CGFloat = 120   // inner post to inner post
    private let keeperHeight: CGFloat = 70
    private var keeperDownY: CGFloat { stagePostLineY - 160 }  // resting on the ground: ball sails over
    private var keeperUpY: CGFloat { goalBallY }              // leaps up to the ball: catches it

    // MARK: - Game State

    enum GameState {
        case aerial, playOn, passing, setShot, gameOver
    }

    private(set) var state: GameState = .aerial

    // MARK: - Core Entities

    var activePlayer: SKNode?
    var teammates: [SKNode] = []          // friendlies that are NOT currently active
    var opponents: [SKNode] = []
    var ball: SKNode?
    private(set) var hasPossession: Bool = false

    // MARK: - Scoring

    private(set) var score: Int = 0 {
        didSet { onScoreChanged?(score) }
    }

    // MARK: - Callbacks to SwiftUI HUD

    var onScoreChanged: ((Int) -> Void)?
    var onGameOver: (() -> Void)?

    // MARK: - Camera & timing

    private let cameraNode = SKCameraNode()
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Input

    private var joystickAnchor: CGPoint?
    private var joystickVector: CGVector = .zero
    private var keyboardVector: CGVector = .zero   // arrow keys / WASD (Mac testing)
    private var pendingPass: SKNode?
    private var activeTouch: UITouch?
    private var joystickBase: SKShapeNode?
    private var joystickKnob: SKShapeNode?

    // MARK: - Ball / phase scratch state

    private var airborne = false
    private var ballVelocity: CGVector = .zero
    private var passTarget: SKNode?
    private var opponentsFrozen = false
    private var fieldBuilt = false
    private var setShotLayer: SKNode?
    private weak var keeper: SKNode?

    // MARK: - Swipe tracking (set shot)

    private var swipeStart: CGPoint?
    private var swipeStartTime: TimeInterval?

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.18, green: 0.42, blue: 0.20, alpha: 1) // grass
        view.isMultipleTouchEnabled = true   // joystick on one finger, pass with another
        physicsWorld.gravity = .zero
        physicsWorld.contactDelegate = self
        camera = cameraNode
        if cameraNode.parent == nil { addChild(cameraNode) }
        buildFieldIfNeeded()
        configureFieldCamera()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        if state == .setShot { configureSetShotCamera() } else { configureFieldCamera() }
    }

    /// Entry point from `AFLGameModel` (start / restart).
    func startMatch() {
        resetMatch()
        beginAerial()
    }

    // MARK: - Field construction

    private func buildFieldIfNeeded() {
        guard !fieldBuilt else { return }
        fieldBuilt = true

        let ground = SKSpriteNode(color: SKColor(red: 0.22, green: 0.5, blue: 0.24, alpha: 1), size: fieldSize)
        ground.position = CGPoint(x: fieldSize.width / 2, y: fieldSize.height / 2)
        ground.zPosition = -10
        addChild(ground)

        // Boundary.
        let boundary = SKShapeNode(rect: CGRect(origin: .zero, size: fieldSize))
        boundary.strokeColor = .white
        boundary.lineWidth = 6
        boundary.zPosition = -9
        addChild(boundary)

        // Forward 50 line.
        let f50 = SKShapeNode()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: forward50X, y: 0))
        p.addLine(to: CGPoint(x: forward50X, y: fieldSize.height))
        f50.path = p
        f50.strokeColor = SKColor.white.withAlphaComponent(0.7)
        f50.lineWidth = 5
        f50.zPosition = -8
        addChild(f50)

        // Goal posts at the right edge (decorative direction marker).
        for (y, tall) in [(450.0, false), (600.0, true), (800.0, true), (950.0, false)] {
            let post = SKSpriteNode(color: .white, size: CGSize(width: 14, height: tall ? 360 : 240))
            post.position = CGPoint(x: fieldSize.width - 2, y: CGFloat(y))
            post.zPosition = -7
            addChild(post)
        }
    }

    // MARK: - Entity factories

    private func makeFriendly(at point: CGPoint) -> SKSpriteNode {
        let node = SKSpriteNode(color: friendlyColor, size: CGSize(width: playerSide, height: playerSide))
        node.position = point
        node.zPosition = 5
        let body = SKPhysicsBody(rectangleOf: node.size)
        body.affectedByGravity = false
        body.allowsRotation = false
        body.collisionBitMask = 0
        body.categoryBitMask = PhysicsCategory.teammate
        node.physicsBody = body
        return node
    }

    private func makeOpponent(at point: CGPoint) -> SKSpriteNode {
        let node = SKSpriteNode(color: SKColor(red: 0.85, green: 0.18, blue: 0.18, alpha: 1),
                                size: CGSize(width: playerSide, height: playerSide))
        node.position = point
        node.zPosition = 5
        let body = SKPhysicsBody(rectangleOf: node.size)
        body.affectedByGravity = false
        body.allowsRotation = false
        body.collisionBitMask = 0
        body.categoryBitMask = PhysicsCategory.opponent
        body.contactTestBitMask = PhysicsCategory.player | PhysicsCategory.ball
        node.physicsBody = body
        return node
    }

    private func makeBall(at point: CGPoint) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: ballRadius)
        node.fillColor = SKColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1)
        node.strokeColor = .clear
        node.position = point
        node.zPosition = 8
        let body = SKPhysicsBody(circleOfRadius: ballRadius)
        body.affectedByGravity = false
        body.collisionBitMask = 0
        body.categoryBitMask = PhysicsCategory.ball
        body.contactTestBitMask = PhysicsCategory.player | PhysicsCategory.opponent
        node.physicsBody = body
        return node
    }

    private var friendlyColor: SKColor { SKColor(red: 0.20, green: 0.75, blue: 0.30, alpha: 1) }
    private var activeColor: SKColor { SKColor(red: 0.45, green: 1.0, blue: 0.50, alpha: 1) }

    // MARK: - Reset / spawn

    private func resetMatch() {
        // Remove dynamic nodes.
        (([activePlayer, ball] + teammates + opponents).compactMap { $0 }).forEach { $0.removeFromParent() }
        setShotLayer?.removeFromParent(); setShotLayer = nil
        removeJoystickVisual()

        teammates.removeAll()
        opponents.removeAll()
        hasPossession = false
        opponentsFrozen = false
        score = 0

        // Friendlies: one active, three teammates. Positions randomized below.
        let active = makeFriendly(at: .zero)
        let mates = [makeFriendly(at: .zero), makeFriendly(at: .zero), makeFriendly(at: .zero)]
        ([active] + mates).forEach { addChild($0) }
        activePlayer = active
        teammates = mates
        refreshFriendlyRoles(([active] + mates))
        placePlayersRandomly()

        let b = makeBall(at: .zero)
        addChild(b)
        ball = b

        configureFieldCamera()
        centerCameraOnActive(snap: true)
    }

    /// Reposition (without recreating) for the next possession after a set shot.
    private func beginNewPossession() {
        setShotLayer?.removeFromParent(); setShotLayer = nil
        opponents.forEach { $0.removeFromParent() }
        opponents.removeAll()
        opponentsFrozen = false
        hasPossession = false

        placePlayersRandomly()

        configureFieldCamera()
        centerCameraOnActive(snap: true)
        beginAerial()
    }

    /// Randomly positions the active player (back/left area) and teammates (spread
    /// across the middle/forward area) for a fresh, non-repeating possession.
    private func placePlayersRandomly() {
        activePlayer?.position = randomPoint(xIn: margin...(fieldSize.width * 0.6),
                                            yIn: margin...(fieldSize.height - margin))
        for mate in teammates {
            mate.position = randomPoint(xIn: (fieldSize.width * 0.35)...(fieldSize.width - margin),
                                        yIn: margin...(fieldSize.height - margin))
        }
    }

    private func refreshFriendlyRoles(_ group: [SKNode]) {
        for n in group {
            let isActive = (n === activePlayer)
            n.physicsBody?.categoryBitMask = isActive ? PhysicsCategory.player : PhysicsCategory.teammate
            n.physicsBody?.contactTestBitMask = isActive ? (PhysicsCategory.ball | PhysicsCategory.opponent) : 0
            (n as? SKSpriteNode)?.color = isActive ? activeColor : friendlyColor

            n.childNode(withName: "highlight")?.removeFromParent()
            if isActive {
                let hl = SKShapeNode(rectOf: CGSize(width: playerSide + 16, height: playerSide + 16), cornerRadius: 6)
                hl.name = "highlight"
                hl.strokeColor = .white
                hl.lineWidth = 5
                hl.fillColor = .clear
                hl.zPosition = -1
                n.addChild(hl)
            }
        }
    }

    // MARK: - Phase: Aerial

    private func beginAerial() {
        state = .aerial
        airborne = true
        passTarget = nil
        joystickVector = .zero
        guard let ball else { return }
        ball.isHidden = false
        ball.zPosition = 8                 // normal field layer (set shot bumps it above the overlay)
        // Launch from the far left at a random height toward a random landing point,
        // so the ball's path isn't aligned with the player — they must run to mark it.
        let startY = CGFloat.random(in: margin...(fieldSize.height - margin))
        ball.position = CGPoint(x: 150, y: startY)
        let targetX: CGFloat = .random(in: 1600...2000)   // lands past mid-field if missed
        let targetY: CGFloat = .random(in: margin...(fieldSize.height - margin))
        let flightTime = (targetX - 150) / aerialSpeed     // keep horizontal pace constant
        ballVelocity = CGVector(dx: aerialSpeed, dy: (targetY - startY) / flightTime)
        ball.removeAllActions()
        ball.run(.repeatForever(.sequence([.scale(to: 1.4, duration: 0.45), .scale(to: 1.0, duration: 0.45)])))
    }

    /// The Mark: caught in the air → whistle, freeze, straight to set shot.
    func attemptMark() {
        guard state == .aerial else { return }
        airborne = false
        ballVelocity = .zero
        ball?.removeAllActions(); ball?.setScale(1.0)
        whistleFeedback()
        showFloatingLabel(String(localized: "AFL_Mark"))
        freezeOpponents()
        hasPossession = true
        beginSetShot()
    }

    private func enterPlayOn() {
        state = .playOn
        airborne = false
        ballVelocity = .zero
        ball?.removeAllActions(); ball?.setScale(1.0)
    }

    // MARK: - Phase: Play on / scramble

    private func gainPossession(by node: SKNode) {
        guard !hasPossession else { return }
        hasPossession = true
        activePlayer = node
        ballVelocity = .zero
        spawnOpponents()
    }

    private func spawnOpponents() {
        opponentsFrozen = false
        // A wall of defenders on the 50-metre line, ahead of the player (between them
        // and goal). Count grows with the score: 4, then +1 every 6 points (capped).
        let count = min(startingDefenders + score / 6, maxDefenders)
        let usableHeight = fieldSize.height - 2 * margin
        for i in 0..<count {
            let y = margin + (CGFloat(i) + 0.5) * usableHeight / CGFloat(count)
            let opp = makeOpponent(at: CGPoint(x: forward50X, y: y))
            addChild(opp)
            opponents.append(opp)
        }
    }

    private func freezeOpponents() { opponentsFrozen = true }

    private func updateOpponentChase(_ dt: CGFloat) {
        guard !opponentsFrozen, let ap = activePlayer else { return }
        for opp in opponents {
            let dir = unitVector(from: opp.position, to: ap.position)
            opp.position = CGPoint(x: opp.position.x + dir.dx * opponentSpeed * dt,
                                   y: opp.position.y + dir.dy * opponentSpeed * dt)
            if hasPossession, distance(opp.position, ap.position) < tackleRadius {
                showFloatingLabel(String(localized: "AFL_Tackled"))
                triggerGameOver()
                return
            }
        }
    }

    /// Teammate AI: forward outlets. Each mate runs goal-ward into its own vertical
    /// lane (so they don't stack), but stops short of the Forward-50 line and peels
    /// away from nearby defenders so it stays open and on-screen as a handpass target.
    private func updateTeammateMovement(_ dt: CGFloat) {
        guard dt > 0, let ap = activePlayer else { return }
        let mates = teammates
        let count = max(mates.count, 1)
        // Lanes are centred on the carrier and fanned out vertically.
        let firstLaneY = ap.position.y - CGFloat(count - 1) / 2 * teammateSpread

        for (i, mate) in mates.enumerated() {
            // Seek a point ahead of the carrier, capped short of the 50.
            let targetX = min(ap.position.x + teammateLeadAhead, forward50X - teammateF50Buffer)
            let targetY = firstLaneY + CGFloat(i) * teammateSpread
            var move = unitVector(from: mate.position, to: CGPoint(x: targetX, y: targetY))

            // Steer away from defenders to stay open / uninterceptable.
            for opp in opponents where distance(mate.position, opp.position) < teammateOpenRadius {
                let away = unitVector(from: opp.position, to: mate.position)
                move.dx += away.dx * 1.5
                move.dy += away.dy * 1.5
            }

            // Don't crowd the ball carrier.
            if distance(mate.position, ap.position) < playerSide * 2 {
                let away = unitVector(from: ap.position, to: mate.position)
                move.dx += away.dx
                move.dy += away.dy
            }

            let mag = hypot(move.dx, move.dy)
            guard mag > 0 else { continue }
            let nx = mate.position.x + move.dx / mag * teammateSpeed * dt
            let ny = mate.position.y + move.dy / mag * teammateSpeed * dt
            mate.position = CGPoint(x: min(max(nx, playerSide / 2), fieldSize.width - playerSide / 2),
                                    y: min(max(ny, playerSide / 2), fieldSize.height - playerSide / 2))
        }
    }

    // MARK: - Phase: Handpass

    /// One-press pass (keyboard / HUD button): handpass to the most open forward teammate.
    func passToBestTeammate() {
        guard hasPossession, state == .playOn, let best = bestPassTarget() else { return }
        handpass(to: best)
    }

    /// Picks the teammate that's the safest, most forward outlet: rewards open space
    /// (distance to the nearest defender) and forward progress, and rejects anyone
    /// with a defender sitting on the pass lane (would just be intercepted).
    private func bestPassTarget() -> SKNode? {
        guard let ap = activePlayer else { return nil }
        var best: SKNode?
        var bestScore = -CGFloat.greatestFiniteMagnitude
        for mate in teammates {
            let openness = opponents.map { distance(mate.position, $0.position) }.min() ?? .greatestFiniteMagnitude
            if openness < interceptRadius * 1.5 { continue }       // too tightly marked
            if defenderOnLane(from: ap.position, to: mate.position) { continue }
            let forwardGain = mate.position.x - ap.position.x
            let score = openness + forwardGain * 0.5
            if score > bestScore { bestScore = score; best = mate }
        }
        return best
    }

    /// True if a defender sits close to the straight line between two points — i.e. the
    /// handpass would likely be intercepted.
    private func defenderOnLane(from: CGPoint, to: CGPoint) -> Bool {
        let lane = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let laneLen = hypot(lane.dx, lane.dy)
        guard laneLen > 0 else { return false }
        for opp in opponents {
            let rel = CGVector(dx: opp.position.x - from.x, dy: opp.position.y - from.y)
            let t = (rel.dx * lane.dx + rel.dy * lane.dy) / (laneLen * laneLen)
            guard t > 0, t < 1 else { continue }                   // only count defenders between the two
            let closest = CGPoint(x: from.x + lane.dx * t, y: from.y + lane.dy * t)
            if distance(opp.position, closest) < interceptRadius { return true }
        }
        return false
    }

    func handpass(to teammate: SKNode) {
        guard hasPossession, state == .playOn, let ball else { return }
        state = .passing
        passTarget = teammate
        hasPossession = false
        let dir = unitVector(from: ball.position, to: teammate.position)
        ballVelocity = CGVector(dx: dir.dx * handpassSpeed, dy: dir.dy * handpassSpeed)
    }

    private func switchControl(to teammate: SKNode) {
        let group = ([activePlayer] + teammates).compactMap { $0 }
        activePlayer = teammate
        teammates = group.filter { $0 !== teammate }
        refreshFriendlyRoles(group)

        hasPossession = true
        passTarget = nil
        ballVelocity = .zero
        state = .playOn
        centerCameraOnActive(snap: true)
    }

    // MARK: - Forward 50 / Set shot

    private func checkForward50() {
        guard hasPossession, let ap = activePlayer, ap.position.x >= forward50X else { return }
        beginSetShot()
    }

    private func beginSetShot() {
        state = .setShot
        resetTouchTracking()

        let layer = SKNode()
        layer.zPosition = 50

        let bg = SKSpriteNode(color: SKColor(red: 0.12, green: 0.32, blue: 0.15, alpha: 1),
                              size: CGSize(width: fieldSize.width, height: 2400))
        bg.position = stageCenter
        layer.addChild(bg)

        // 4 posts across the top: inner gap = goal, inner→outer = behind.
        for dx in [-360.0, -120.0, 120.0, 360.0] {
            let inner = abs(dx) < 200
            let post = SKSpriteNode(color: .white, size: CGSize(width: 18, height: inner ? 360 : 240))
            post.position = CGPoint(x: stageCenter.x + CGFloat(dx), y: stagePostLineY)
            layer.addChild(post)
        }

        let hint = SKLabelNode(text: String(localized: "AFL_Swipe_Hint"))
        hint.fontName = "AvenirNext-Bold"
        hint.fontSize = 70
        hint.fontColor = .white
        hint.position = CGPoint(x: stageCenter.x, y: stageCenter.y - 760)
        layer.addChild(hint)

        // A shooter marker behind the ball.
        let shooter = SKSpriteNode(color: activeColor, size: CGSize(width: playerSide, height: playerSide))
        shooter.position = CGPoint(x: stageCenter.x, y: stageBall.y - 90)
        layer.addChild(shooter)

        // Goalkeeper that rests on the ground and leaps up to the ball's height — shoot
        // when he's DOWN. He dwells on the ground to give a beatable window.
        let gk = SKSpriteNode(color: SKColor(red: 0.85, green: 0.18, blue: 0.18, alpha: 1),
                              size: CGSize(width: keeperHalfWidth * 2, height: keeperHeight))
        gk.position = CGPoint(x: stageCenter.x, y: keeperDownY)
        gk.zPosition = 5
        gk.run(.repeatForever(.sequence([
            .moveTo(y: keeperUpY, duration: 0.4),
            .wait(forDuration: 0.2),
            .moveTo(y: keeperDownY, duration: 0.4),
            .wait(forDuration: 0.5)
        ])))
        layer.addChild(gk)
        keeper = gk

        addChild(layer)
        setShotLayer = layer

        ball?.removeAllActions()
        ball?.setScale(1.0)
        ball?.isHidden = false
        ball?.zPosition = 60               // above the set-shot overlay (layer is 50)
        ball?.position = stageBall

        configureSetShotCamera()
    }

    /// `power` = swipe speed, `angle` = swipe direction. Up-and-straight scores.
    func handleSwipeKick(power: CGFloat, angle: CGFloat) {
        guard state == .setShot, let ball else { return }
        let dirX = cos(angle), dirY = sin(angle)
        let minPower: CGFloat = 600

        // Must swipe up with enough power.
        guard dirY > 0.25, power >= minPower else {
            // Weak kick: low arc that falls short.
            animateShot(to: CGPoint(x: stageBall.x, y: stagePostLineY - 250),
                        arcHeight: 110, duration: 0.5) { [weak self] in
                self?.resolveShot(points: 0, labelText: nil)
            }
            return
        }

        // Project from ball start to the post line; lateral drift from swipe slant.
        let rise = stagePostLineY - stageBall.y
        var landingX = stageBall.x + (dirX / dirY) * rise
        // Slight inaccuracy when over-hit.
        if power > 2600 { landingX += CGFloat.random(in: -90...90) }
        landingX = min(max(landingX, stageCenter.x - 700), stageCenter.x + 700)

        let dx = abs(landingX - stageCenter.x)
        let isGoalBound = dx <= 120
        let isBehind = dx > 120 && dx <= 360

        animateShot(to: CGPoint(x: landingX, y: goalBallY),
                    arcHeight: 260, duration: 0.6) { [weak self] in
            guard let self else { return }
            if isGoalBound {
                if self.keeperSaves(landingX: landingX) {
                    self.resolveShot(points: 0, labelText: String(localized: "AFL_Saved"))
                } else {
                    self.resolveShot(points: 6, labelText: String(localized: "AFL_Goal"))
                }
            } else if isBehind {
                self.resolveShot(points: 1, labelText: String(localized: "AFL_Behind"))
            } else {
                self.resolveShot(points: 0, labelText: nil)
            }
        }
    }

    /// True if the keeper is actually touching the ball at the goal line on arrival
    /// (overlap in both x and y).
    private func keeperSaves(landingX: CGFloat) -> Bool {
        guard let keeper else { return false }
        let dx = abs(landingX - keeper.position.x)
        let dy = abs(goalBallY - keeper.position.y)
        return dx <= keeperHalfWidth + ballRadius && dy <= keeperHeight / 2 + ballRadius
    }

    /// Flies the ball from its current spot to `target` along a parabolic arc, growing
    /// (to read as height/distance), spinning, and leaving a short fading trail.
    private func animateShot(to target: CGPoint, arcHeight: CGFloat,
                             duration: TimeInterval, completion: @escaping () -> Void) {
        guard let ball else { return }
        let start = ball.position
        ball.removeAllActions()

        var trailAccumulator: CGFloat = 0
        let fly = SKAction.customAction(withDuration: duration) { [weak self] node, elapsed in
            guard duration > 0 else { return }
            let t = max(0, min(1, CGFloat(elapsed) / CGFloat(duration)))
            let x = start.x + (target.x - start.x) * t
            let y = start.y + (target.y - start.y) * t
            let arc = sin(t * .pi) * arcHeight          // peaks mid-flight
            node.position = CGPoint(x: x, y: y + arc)
            node.setScale(1 + sin(t * .pi) * 0.8)       // looks higher near the apex

            // Drop a trail dot roughly every frame-ish without flooding.
            trailAccumulator += 1
            if trailAccumulator >= 2 {
                trailAccumulator = 0
                self?.dropBallTrail(at: node.position, scale: node.xScale)
            }
        }
        let spin = SKAction.rotate(byAngle: .pi * 4, duration: duration)
        ball.run(.group([fly, spin])) {
            ball.zRotation = 0
            ball.setScale(1)
            completion()
        }
    }

    private func dropBallTrail(at point: CGPoint, scale: CGFloat) {
        let dot = SKShapeNode(circleOfRadius: ballRadius * 0.55 * scale)
        dot.fillColor = SKColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 0.45)
        dot.strokeColor = .clear
        dot.position = point
        dot.zPosition = 59                              // just under the ball, above the overlay
        addChild(dot)
        dot.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
    }

    private func resolveShot(points: Int, labelText: String?) {
        if points > 0 { score += points }
        if let labelText { showFloatingLabel(labelText) }
        run(.wait(forDuration: 1.0)) { [weak self] in
            guard let self, self.state == .setShot else { return }
            self.beginNewPossession()
        }
    }

    // MARK: - Game Over

    private func triggerGameOver() {
        guard state != .gameOver else { return }
        state = .gameOver
        resetTouchTracking()
        onGameOver?()
    }

    // MARK: - Touch Handling

    /// Clears virtual-joystick / pass touch tracking. Called when leaving field play
    /// (set shot, game over, new possession) so a stale, already-ended touch can't be
    /// mistaken for a live joystick — which would block the next joystick from appearing.
    private func resetTouchTracking() {
        activeTouch = nil
        joystickAnchor = nil
        joystickVector = .zero
        pendingPass = nil
        removeJoystickVisual()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let location = touch.location(in: self)
            switch state {
            case .setShot:
                swipeStart = location
                swipeStartTime = touch.timestamp
            case .aerial, .playOn:
                if activeTouch == nil {
                    // First finger → virtual joystick (or a single-finger tap-to-pass).
                    activeTouch = touch
                    joystickAnchor = location
                    joystickVector = .zero
                    pendingPass = (hasPossession && state == .playOn) ? teammate(at: location) : nil
                    if pendingPass == nil { showJoystickVisual(at: location) }
                } else if hasPossession, state == .playOn {
                    // Second finger while running → handpass to the tapped/nearest teammate
                    // (or the best option), without disturbing the joystick.
                    if let target = teammate(at: location) ?? bestPassTarget() {
                        handpass(to: target)
                    }
                }
            case .passing, .gameOver:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if state == .setShot { return }
        guard let touch = touches.first(where: { $0 === activeTouch }),
              let anchor = joystickAnchor else { return }
        let location = touch.location(in: self)

        let delta = CGVector(dx: location.x - anchor.x, dy: location.y - anchor.y)
        let mag = hypot(delta.dx, delta.dy)
        let deadzone: CGFloat = 28
        let passCancelDistance: CGFloat = 120   // a held pass only cancels on a deliberate drag

        // While a pass is pending, ignore tap jitter so the tap survives; only a clear
        // drag cancels it and hands control to the joystick.
        if pendingPass != nil {
            guard mag > passCancelDistance else { return }
            pendingPass = nil
            showJoystickVisual(at: anchor)
        }

        if mag > deadzone {
            joystickVector = CGVector(dx: delta.dx / mag, dy: delta.dy / mag)
            updateJoystickVisual(to: location)
        } else {
            joystickVector = .zero
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if state == .setShot {
            if let touch = touches.first {
                endSwipe(at: touch.location(in: self), time: touch.timestamp)
            }
            return
        }

        guard touches.contains(where: { $0 === activeTouch }) else { return }
        if let target = pendingPass { handpass(to: target) }
        joystickVector = .zero
        joystickAnchor = nil
        pendingPass = nil
        activeTouch = nil
        removeJoystickVisual()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0 === activeTouch }) {
            joystickVector = .zero
            joystickAnchor = nil
            pendingPass = nil
            activeTouch = nil
            removeJoystickVisual()
        }
        swipeStart = nil
        swipeStartTime = nil
    }

    /// Picks a teammate to pass to from a tap. A direct hit always counts; otherwise the
    /// nearest teammate within `passTapRadius` wins, so the small, moving squares are easy
    /// to target on a zoomed-out phone screen.
    private func teammate(at point: CGPoint) -> SKNode? {
        let hits = nodes(at: point)
        if let direct = teammates.first(where: { mate in hits.contains { $0 === mate || $0.parent === mate } }) {
            return direct
        }
        return teammates
            .map { ($0, distance(point, $0.position)) }
            .filter { $0.1 <= passTapRadius }
            .min { $0.1 < $1.1 }?.0
    }

    private func endSwipe(at point: CGPoint, time: TimeInterval) {
        defer { swipeStart = nil; swipeStartTime = nil }
        guard let start = swipeStart, let startTime = swipeStartTime else { return }
        let dx = point.x - start.x
        let dy = point.y - start.y
        let distance = hypot(dx, dy)
        let duration = max(time - startTime, 0.0001)
        let power = CGFloat(distance / duration)
        let angle = atan2(dy, dx)
        handleSwipeKick(power: power, angle: angle)
    }

    // MARK: - Update loop

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdateTime == 0 ? 0 : CGFloat(min(currentTime - lastUpdateTime, 1.0 / 30.0))
        lastUpdateTime = currentTime

        switch state {
        case .aerial:
            applyJoystick(dt)
            moveBall(dt)
            if let ap = activePlayer, let b = ball, airborne, distance(ap.position, b.position) < markRadius {
                attemptMark()
            } else if let b = ball, b.position.x > 1500 {
                enterPlayOn()
            }

        case .playOn:
            applyJoystick(dt)
            if hasPossession {
                attachBallToCarrier()
                updateTeammateMovement(dt)
                updateOpponentChase(dt)
                checkForward50()
            } else if let ap = activePlayer, let b = ball, distance(ap.position, b.position) < pickupRadius {
                gainPossession(by: ap)
            }

        case .passing:
            moveBall(dt)
            updateOpponentChase(dt)
            if let b = ball {
                for opp in opponents where distance(opp.position, b.position) < interceptRadius {
                    showFloatingLabel(String(localized: "AFL_Intercepted"))
                    triggerGameOver()
                    return
                }
                if let target = passTarget, distance(b.position, target.position) < arriveRadius {
                    switchControl(to: target)
                }
            }

        case .setShot, .gameOver:
            break
        }

        // Follow the active player only while still in a field phase. A transition
        // into .setShot/.gameOver (e.g. via a Mark or crossing the Forward 50) has
        // already framed the camera; don't override it the same frame.
        switch state {
        case .aerial, .playOn, .passing:
            centerCameraOnActive(snap: false)
        case .setShot, .gameOver:
            break
        }
    }

    /// Sets the keyboard-driven movement direction (arrow keys / WASD). Expects an
    /// already-normalized vector; `.zero` stops keyboard movement.
    func setKeyboardDirection(_ v: CGVector) { keyboardVector = v }

    private func applyJoystick(_ dt: CGFloat) {
        // Touch joystick takes priority; fall back to the keyboard direction.
        let move = (joystickVector.dx != 0 || joystickVector.dy != 0) ? joystickVector : keyboardVector
        guard dt > 0, let ap = activePlayer, move.dx != 0 || move.dy != 0 else { return }
        let nx = ap.position.x + move.dx * playerSpeed * dt
        let ny = ap.position.y + move.dy * playerSpeed * dt
        ap.position = CGPoint(x: min(max(nx, playerSide / 2), fieldSize.width - playerSide / 2),
                              y: min(max(ny, playerSide / 2), fieldSize.height - playerSide / 2))
    }

    private func moveBall(_ dt: CGFloat) {
        guard dt > 0, let b = ball else { return }
        b.position = CGPoint(x: b.position.x + ballVelocity.dx * dt,
                             y: b.position.y + ballVelocity.dy * dt)
    }

    private func attachBallToCarrier() {
        guard let ap = activePlayer, let b = ball else { return }
        b.position = CGPoint(x: ap.position.x + 36, y: ap.position.y)
    }

    // MARK: - Camera

    private func configureFieldCamera() {
        guard size.height > 0 else { return }
        cameraNode.setScale(worldVisibleHeight / size.height)
    }

    private func configureSetShotCamera() {
        guard size.height > 0 else { return }
        cameraNode.setScale(setShotVisibleHeight / size.height)
        cameraNode.position = stageCenter
    }

    private func centerCameraOnActive(snap: Bool) {
        guard let ap = activePlayer else { return }
        let halfW = size.width * cameraNode.xScale / 2
        let halfH = size.height * cameraNode.yScale / 2
        let targetX = fieldSize.width > halfW * 2
            ? min(max(ap.position.x, halfW), fieldSize.width - halfW) : fieldSize.width / 2
        let targetY = fieldSize.height > halfH * 2
            ? min(max(ap.position.y, halfH), fieldSize.height - halfH) : fieldSize.height / 2
        cameraNode.position = CGPoint(x: targetX, y: targetY)
    }

    // MARK: - Joystick visual

    private func showJoystickVisual(at point: CGPoint) {
        removeJoystickVisual()
        let base = SKShapeNode(circleOfRadius: 130)
        base.strokeColor = SKColor.white.withAlphaComponent(0.5)
        base.lineWidth = 8
        base.fillColor = SKColor.white.withAlphaComponent(0.08)
        base.position = point
        base.zPosition = 40
        addChild(base)
        let knob = SKShapeNode(circleOfRadius: 55)
        knob.fillColor = SKColor.white.withAlphaComponent(0.35)
        knob.strokeColor = .clear
        knob.position = point
        knob.zPosition = 41
        addChild(knob)
        joystickBase = base
        joystickKnob = knob
    }

    private func updateJoystickVisual(to point: CGPoint) {
        guard let base = joystickBase else { return }
        let delta = CGVector(dx: point.x - base.position.x, dy: point.y - base.position.y)
        let mag = hypot(delta.dx, delta.dy)
        let maxR: CGFloat = 130
        let clamped = mag > maxR ? CGVector(dx: delta.dx / mag * maxR, dy: delta.dy / mag * maxR) : delta
        joystickKnob?.position = CGPoint(x: base.position.x + clamped.dx, y: base.position.y + clamped.dy)
    }

    private func removeJoystickVisual() {
        joystickBase?.removeFromParent(); joystickBase = nil
        joystickKnob?.removeFromParent(); joystickKnob = nil
    }

    // MARK: - Feedback helpers

    private func showFloatingLabel(_ text: String) {
        let label = SKLabelNode(text: text)
        label.fontName = "AvenirNext-Heavy"
        label.fontSize = 64
        label.fontColor = .white
        label.setScale(cameraNode.xScale)
        label.position = CGPoint(x: 0, y: size.height * 0.28 * cameraNode.yScale)
        label.zPosition = 100
        cameraNode.addChild(label)
        label.run(.sequence([
            .group([.scale(to: 1.3 * cameraNode.xScale, duration: 0.5), .fadeOut(withDuration: 1.0)]),
            .removeFromParent()
        ]))
    }

    private func whistleFeedback() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        let flash = SKSpriteNode(color: SKColor.white.withAlphaComponent(0.45),
                                 size: CGSize(width: size.width * cameraNode.xScale,
                                              height: size.height * cameraNode.yScale))
        flash.zPosition = 99
        cameraNode.addChild(flash)
        flash.run(.sequence([.fadeOut(withDuration: 0.35), .removeFromParent()]))
    }

    // MARK: - Vector math

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func randomPoint(xIn xr: ClosedRange<CGFloat>, yIn yr: ClosedRange<CGFloat>) -> CGPoint {
        CGPoint(x: .random(in: xr), y: .random(in: yr))
    }

    private func unitVector(from: CGPoint, to: CGPoint) -> CGVector {
        let dx = to.x - from.x, dy = to.y - from.y
        let mag = hypot(dx, dy)
        return mag == 0 ? .zero : CGVector(dx: dx / mag, dy: dy / mag)
    }
}

// MARK: - Physics Contacts (backup to the distance checks above)

extension AFLGameScene: SKPhysicsContactDelegate {
    func didBegin(_ contact: SKPhysicsContact) {
        let mask = contact.bodyA.categoryBitMask | contact.bodyB.categoryBitMask
        switch mask {
        case PhysicsCategory.player | PhysicsCategory.opponent:
            if hasPossession, state == .playOn {
                showFloatingLabel(String(localized: "AFL_Tackled"))
                triggerGameOver()
            }
        case PhysicsCategory.ball | PhysicsCategory.opponent:
            if state == .passing {
                showFloatingLabel(String(localized: "AFL_Intercepted"))
                triggerGameOver()
            }
        case PhysicsCategory.player | PhysicsCategory.ball:
            if state == .playOn, !hasPossession, let ap = activePlayer { gainPossession(by: ap) }
        default:
            break
        }
    }
}
