//
//  BaseGameScene.swift
//  Arcade Mix
//
//  Sport-agnostic arcade engine shared by the AFL and Rugby scenes. It owns the
//  field, camera, virtual-joystick/keyboard input, possession, the pass engine,
//  opponent/teammate AI, the staged swipe-kick, and scoring/HUD callbacks.
//
//  Sport-specific rules are expressed as overridable hook methods (see "Hooks")
//  plus a `SportConfig` value injected at init. The base defaults reproduce AFL
//  behavior, so a subclass only overrides what genuinely differs.
//
//  Flow:  .aerial → (caught) hook  |  .aerial → (landed) hook
//         .playOn → (handpass) .passing → (caught) .playOn (control switches)
//         .playOn → (cross scoring line) .kicking → (swipe) score → next possession
//

import SpriteKit
import GameplayKit
import UIKit

class BaseGameScene: SKScene {

    // MARK: - Config

    let config: SportConfig

    init(size: CGSize, config: SportConfig) {
        self.config = config
        super.init(size: size)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Convenience accessors for the most-used config fields.
    private var fieldSize: CGSize { config.fieldSize }
    var scoringLineX: CGFloat { config.scoringLineX }
    private var playerSide: CGFloat { config.playerSide }
    private var ballRadius: CGFloat { config.ballRadius }
    private var margin: CGFloat { config.margin }

    // MARK: - Staged kick geometry (a clean area of the world, above the field)

    var stageCenter: CGPoint { CGPoint(x: fieldSize.width / 2, y: fieldSize.height + 1600) }
    var stageBall: CGPoint { CGPoint(x: stageCenter.x, y: stageCenter.y - 500) }
    var stagePostLineY: CGFloat { stageCenter.y + 420 }
    var goalBallY: CGFloat { stagePostLineY + 120 }   // staged kicks arrive high at the posts

    /// Lateral shift of the kick's launch point (ball + shooter) from the stage centre.
    /// AFL keeps it 0 (centred set shot); Rugby offsets it to the spot the try was
    /// scored, so wide conversions must be angled back toward the central posts.
    var kickLateralOffset: CGFloat = 0
    var kickBallX: CGFloat { stageCenter.x + kickLateralOffset }

    // MARK: - Game State

    private(set) var state: GameState = .aerial

    // MARK: - Core entities

    var activePlayer: SKNode?
    var teammates: [SKNode] = []          // friendlies that are NOT currently active
    var opponents: [SKNode] = []          // pressing defenders that chase the carrier / mark outlets
    var lineDefenders: [SKNode] = []      // back line that holds near the scoring line to catch a runner
    var ball: SKNode?
    private(set) var hasPossession: Bool = false

    /// The teammate the next pass will go to in open play, shown with a subtle highlight.
    /// Driven by the joystick direction (touch) or cycled with Q/E (keyboard).
    private weak var aimedTeammate: SKNode?

    // MARK: - Scoring

    private(set) var score: Int = 0 {
        didSet { onScoreChanged?(score) }
    }
    func addScore(_ n: Int) { score += n }

    /// Squad size at the start: the controlled player plus this many teammates. The squad
    /// then gains a teammate every 30 points (see `topUpTeammates`), but stops once the
    /// difficulty has plateaued so reinforcements don't outpace a defence that can't grow.
    private let baseTeammateCount = 3
    private var targetTeammateCount: Int { baseTeammateCount + min(score, difficultyPlateauScore) / 30 }

    /// Hook: the score beyond which no difficulty lever still increases — teammate growth
    /// stops here. Default (AFL): the defender count caps at 66 (aggression already maxed at
    /// 60, and there's no speed ramp). Rugby overrides it to its later, speed-ramp plateau.
    var difficultyPlateauScore: Int { 66 }

    // MARK: - Callbacks to SwiftUI HUD

    var onScoreChanged: ((Int) -> Void)?
    var onGameOver: (() -> Void)?

    // MARK: - Camera & timing

    private let cameraNode = SKCameraNode()
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Input

    private var joystickAnchor: CGPoint?
    private var joystickVector: CGVector = .zero
    private var keyboardVector: CGVector = .zero
    private var pendingPass: SKNode?
    private var activeTouch: UITouch?
    private var joystickBase: SKShapeNode?
    private var joystickKnob: SKShapeNode?

    // MARK: - Ball / phase scratch state

    private var airborne = false
    private var ballVelocity: CGVector = .zero
    private var ballGround: CGPoint = .zero
    var flightStart: CGPoint = .zero
    var flightEnd: CGPoint = .zero
    private var flightDuration: CGFloat = 0
    private var flightElapsed: CGFloat = 0
    private var passTarget: SKNode?
    private var opponentsFrozen = false
    private var fieldBuilt = false
    private var setShotLayer: SKNode?
    private var tackleCooldown: TimeInterval = 0

    /// An "X" drawn on the ground at the kicked-in ball's landing spot, shown for the
    /// whole aerial flight so the player knows where to run.
    private weak var landingMarker: SKNode?

    // MARK: - Swipe tracking (staged kick)

    private var swipeStart: CGPoint?
    private var swipeStartTime: TimeInterval?

    // MARK: - Pause / restart-on-touch

    private var touchesDown = Set<UITouch>()   // every finger currently on screen
    private var resumeArmed = false            // true once all fingers have lifted since pausing
    private var onResumeFromPause: (() -> Void)?
    private weak var holdLabel: SKNode?
    private(set) var isInteractiveRestart = false   // dragging teammates before a restart
    private weak var draggedNode: SKNode?

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = config.grassColor
        view.isMultipleTouchEnabled = true
        physicsWorld.gravity = .zero
        physicsWorld.contactDelegate = self
        camera = cameraNode
        if cameraNode.parent == nil { addChild(cameraNode) }
        buildFieldIfNeeded()
        configureFieldCamera()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        if state == .kicking { configureSetShotCamera() } else { configureFieldCamera() }
    }

    /// Entry point from the game model (start / restart).
    func startMatch() {
        resetMatch()
        beginAerial()
    }

    // MARK: - Field construction

    private func buildFieldIfNeeded() {
        guard !fieldBuilt else { return }
        fieldBuilt = true

        let ground = SKSpriteNode(color: config.groundColor, size: fieldSize)
        ground.position = CGPoint(x: fieldSize.width / 2, y: fieldSize.height / 2)
        ground.zPosition = -10
        addChild(ground)

        let boundary = SKShapeNode(rect: CGRect(origin: .zero, size: fieldSize))
        boundary.strokeColor = .white
        boundary.lineWidth = 6
        boundary.zPosition = -9
        addChild(boundary)

        // Scoring line.
        let line = SKShapeNode()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: scoringLineX, y: 0))
        p.addLine(to: CGPoint(x: scoringLineX, y: fieldSize.height))
        line.path = p
        line.strokeColor = SKColor.white.withAlphaComponent(0.7)
        line.lineWidth = 5
        line.zPosition = -8
        addChild(line)

        buildFieldDecorations()
    }

    /// Hook: sport-specific field markings (e.g. goal posts at the scoring end).
    func buildFieldDecorations() {
        for (y, tall) in [(450.0, false), (600.0, true), (800.0, true), (950.0, false)] {
            let post = SKSpriteNode(color: .white, size: CGSize(width: 14, height: tall ? 360 : 240))
            post.position = CGPoint(x: fieldSize.width - 2, y: CGFloat(y))
            post.zPosition = -7
            addChild(post)
        }
    }

    // MARK: - Entity factories

    private func makeFriendly(at point: CGPoint) -> SKSpriteNode {
        let node = SKSpriteNode(color: config.friendlyColor, size: CGSize(width: playerSide, height: playerSide))
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
        let node = SKSpriteNode(color: config.opponentColor, size: CGSize(width: playerSide, height: playerSide))
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
        node.fillColor = config.ballColor
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

    // MARK: - Reset / spawn

    private func resetMatch() {
        (([activePlayer, ball] + teammates + opponents + lineDefenders).compactMap { $0 }).forEach { $0.removeFromParent() }
        setShotLayer?.removeFromParent(); setShotLayer = nil
        removeLandingMarker()
        holdLabel?.removeFromParent(); holdLabel = nil
        onResumeFromPause = nil
        resumeArmed = false
        touchesDown.removeAll()
        removeJoystickVisual()

        teammates.removeAll()
        opponents.removeAll()
        lineDefenders.removeAll()
        hasPossession = false
        opponentsFrozen = false
        score = 0

        let active = makeFriendly(at: .zero)
        addChild(active)
        activePlayer = active
        teammates = []
        for _ in 0..<baseTeammateCount {
            let mate = makeFriendly(at: .zero)
            addChild(mate)
            teammates.append(mate)
        }
        refreshFriendlyRoles([active] + teammates)
        placePlayersRandomly()

        let b = makeBall(at: .zero)
        addChild(b)
        ball = b

        configureFieldCamera()
        centerCameraOnActive(snap: true)
    }

    /// Reposition (without recreating) for the next possession after a staged kick.
    func beginNewPossession() {
        setShotLayer?.removeFromParent(); setShotLayer = nil
        (opponents + lineDefenders).forEach { $0.removeFromParent() }
        opponents.removeAll()
        lineDefenders.removeAll()
        opponentsFrozen = false
        hasPossession = false

        topUpTeammates()
        placePlayersRandomly()

        configureFieldCamera()
        centerCameraOnActive(snap: true)
        beginAerial()
    }

    /// Reinforcements: the squad gains a teammate every 30 points. Called at the start of a
    /// possession so newly earned mates join for the next set (then `placePlayersRandomly`
    /// positions them).
    private func topUpTeammates() {
        guard teammates.count < targetTeammateCount, let active = activePlayer else { return }
        while teammates.count < targetTeammateCount {
            let mate = makeFriendly(at: .zero)
            addChild(mate)
            teammates.append(mate)
        }
        refreshFriendlyRoles([active] + teammates)
    }

    /// Hook: where the active player and teammates start each possession.
    func placePlayersRandomly() {
        activePlayer?.position = randomPoint(xIn: margin...(fieldSize.width * 0.6),
                                             yIn: margin...(fieldSize.height - margin))
        for mate in teammates {
            mate.position = randomPoint(xIn: (fieldSize.width * 0.35)...(fieldSize.width - margin),
                                        yIn: margin...(fieldSize.height - margin))
        }
    }

    func refreshFriendlyRoles(_ group: [SKNode]) {
        for n in group {
            let isActive = (n === activePlayer)
            n.physicsBody?.categoryBitMask = isActive ? PhysicsCategory.player : PhysicsCategory.teammate
            n.physicsBody?.contactTestBitMask = isActive ? (PhysicsCategory.ball | PhysicsCategory.opponent) : 0
            (n as? SKSpriteNode)?.color = isActive ? config.activeColor : config.friendlyColor
            n.alpha = 1

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

    func beginAerial() {
        state = .aerial
        airborne = true
        passTarget = nil
        joystickVector = .zero
        kickLateralOffset = 0
        guard let ball else { return }
        ball.isHidden = false
        ball.zPosition = 8
        configureKickoffFlight()
        ballGround = flightStart
        flightDuration = abs(flightEnd.x - flightStart.x) / config.kickoffSpeed
        flightElapsed = 0
        ball.removeAllActions()
        ball.position = flightStart
        ball.setScale(config.minFlightScale)
        showLandingMarker(at: flightEnd)
    }

    /// Hook: carrier movement speed during the kickoff flight, relative to normal. Default
    /// 1.0 (Rugby is unchanged); AFL slows the chase so getting under the ball to take the
    /// mark demands more commitment.
    var aerialPlayerSpeedFactor: CGFloat { 1.0 }

    /// Hook: set `flightStart` / `flightEnd` for the kicked-in ball. Default = AFL
    /// (kicked from the back-left toward midfield).
    func configureKickoffFlight() {
        let startY = CGFloat.random(in: margin...(fieldSize.height - margin))
        let targetX: CGFloat = .random(in: 1600...2000)
        let targetY: CGFloat = .random(in: margin...(fieldSize.height - margin))
        flightStart = CGPoint(x: 150, y: startY)
        flightEnd = CGPoint(x: targetX, y: targetY)
    }

    // MARK: - Landing marker

    /// Drop a pulsing "X" on the ground at `point` (the kicked ball's landing spot) so the
    /// player can read where to run during the aerial flight. Replaces any existing marker.
    private func showLandingMarker(at point: CGPoint) {
        removeLandingMarker()

        let arm: CGFloat = playerSide * 0.7
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -arm, y: -arm)); path.addLine(to: CGPoint(x: arm, y: arm))
        path.move(to: CGPoint(x: -arm, y: arm)); path.addLine(to: CGPoint(x: arm, y: -arm))

        let cross = SKShapeNode(path: path)
        cross.name = "landingMarker"
        cross.strokeColor = .white
        cross.lineWidth = 9
        cross.lineCap = .round
        cross.glowWidth = 2
        cross.position = point
        cross.zPosition = 1   // on the ground, beneath players (z 5) and the ball (z 8)
        cross.run(.repeatForever(.sequence([
            .scale(to: 1.18, duration: 0.45),
            .scale(to: 1.0, duration: 0.45)
        ])))
        addChild(cross)
        landingMarker = cross
    }

    private func removeLandingMarker() {
        landingMarker?.removeFromParent()
        landingMarker = nil
        // Belt-and-braces: clear any stray marker if the weak ref was lost.
        childNode(withName: "landingMarker")?.removeFromParent()
    }

    /// Common cleanup before the catch hook fires.
    private func handleAerialCatch(by node: SKNode) {
        airborne = false
        ballVelocity = .zero
        ball?.removeAllActions(); ball?.setScale(1.0)
        removeLandingMarker()
        onAerialCaught(by: node)
    }

    /// Hook: the active player reached the ball in the air. Default = AFL Mark →
    /// whistle, freeze, possession, staged set shot.
    func onAerialCaught(by node: SKNode) {
        whistleFeedback()
        showFloatingLabel(String(localized: "AFL_Mark"))
        freezeOpponents()
        hasPossession = true
        beginKickPhase()
    }

    /// Hook: the ball completed its flight uncaught. Default = drop it as a loose ball.
    func onAerialLanded(at point: CGPoint) {
        ball?.position = point
        enterPlayOn()
    }

    /// `resetBall: false` leaves any running ball action (e.g. a loose-ball roll) intact.
    func enterPlayOn(resetBall: Bool = true) {
        state = .playOn
        airborne = false
        ballVelocity = .zero
        if resetBall { ball?.removeAllActions(); ball?.setScale(1.0) }
    }

    // MARK: - Phase: Play on / scramble

    func gainPossession(by node: SKNode) {
        guard !hasPossession else { return }
        hasPossession = true
        activePlayer = node
        ballVelocity = .zero
        spawnOpponents()
    }

    func spawnOpponents() {
        opponentsFrozen = false
        // Difficulty ramps the total with the score: 4, then +1 every 6 points (capped).
        let total = min(config.startingDefenders + score / 6, config.maxDefenders)
        let chaserCount = min(total, config.maxChasers)
        let linerCount = total - chaserCount          // overflow above the chaser cap → back line
        let usableHeight = fieldSize.height - 2 * margin

        // Chasers: the pressing wall that hunts the carrier and marks pass outlets.
        for i in 0..<chaserCount {
            let y = margin + (CGFloat(i) + 0.5) * usableHeight / CGFloat(chaserCount)
            let opp = makeOpponent(at: CGPoint(x: scoringLineX, y: y))
            addChild(opp)
            opponents.append(opp)
        }

        // Back line: a darker-shaded goal-side cordon that boxes the carrier in (see
        // updateLineDefenders). Spawn them spread along the line; they push up from there.
        let spread = max(linerCount, 1)
        for i in 0..<linerCount {
            let y = margin + (CGFloat(i) + 0.5) * usableHeight / CGFloat(spread)
            let d = makeOpponent(at: CGPoint(x: lineDefenderX, y: y))
            d.color = Self.lineDefenderColor
            addChild(d)
            lineDefenders.append(d)
        }
    }

    /// X where the back line first spawns — just in front of the scoring line; they then
    /// push up to box the carrier (see `updateLineDefenders`).
    private var lineDefenderX: CGFloat { max(scoringLineX - playerSide * 1.5, margin) }

    private static let lineDefenderColor = SKColor(red: 0.55, green: 0.10, blue: 0.10, alpha: 1)

    /// Goal-side cordon geometry: how far ahead of the carrier the box sits, how wide a fan
    /// it spreads (0 rad = straight toward the scoring line), and the furthest up-field the
    /// line will advance — they hold this far in front of the line until the carrier nears.
    private let lineDefenderBoxRadius: CGFloat = 190
    private let lineDefenderArc: CGFloat = .pi * 8 / 9   // 160° fan on the goal side
    private let lineDefenderHoldDepth: CGFloat = 300     // hold this far in front of the scoring line

    /// Move the back line each frame: fan out over a goal-side arc centred on the carrier so
    /// they keep the carrier's lane and use their numbers to box in the forward and lateral
    /// escape routes (instead of sitting in a flat line at the scoring line). Tackle on contact.
    private func updateLineDefenders(_ dt: CGFloat) {
        guard !opponentsFrozen, dt > 0, let ap = activePlayer, !lineDefenders.isEmpty else { return }
        let speed = effectiveOpponentSpeed
        let carrier = ap.position
        let count = lineDefenders.count
        // Don't advance past the hold line until the carrier comes up — otherwise the box,
        // centred on the carrier, drags the back line too far up the field.
        let holdX = scoringLineX - lineDefenderHoldDepth

        for (i, d) in lineDefenders.enumerated() {
            // Spread evenly across the arc; the box stays goal-side, holds near the scoring
            // line when the carrier is deep, and never chases past the line itself.
            let frac = count == 1 ? 0.5 : CGFloat(i) / CGFloat(count - 1)
            let angle = -lineDefenderArc / 2 + frac * lineDefenderArc
            let boxX = carrier.x + cos(angle) * lineDefenderBoxRadius
            let tx = min(max(boxX, holdX), scoringLineX - playerSide / 2)
            let ty = carrier.y + sin(angle) * lineDefenderBoxRadius
            var move = unitVector(from: d.position, to: CGPoint(x: tx, y: ty))
            for other in lineDefenders where other !== d && distance(d.position, other.position) < config.opponentSeparation {
                let away = unitVector(from: other.position, to: d.position)
                move.dx += away.dx
                move.dy += away.dy
            }
            let mag = hypot(move.dx, move.dy)
            if mag > 0 {
                let nx = d.position.x + move.dx / mag * speed * dt
                let ny = d.position.y + move.dy / mag * speed * dt
                d.position = CGPoint(x: min(max(nx, playerSide / 2), fieldSize.width - playerSide / 2),
                                     y: min(max(ny, playerSide / 2), fieldSize.height - playerSide / 2))
            }
            if hasPossession, distance(d.position, ap.position) < config.tackleRadius {
                registerTackle(at: ap.position)
                return
            }
        }
    }

    func freezeOpponents() { opponentsFrozen = true }
    func unfreezeOpponents() { opponentsFrozen = false }

    /// Hook: opponent chase speed. Default = the config value; a sport can ramp it with
    /// the score once the other difficulty levers (count, blocking) are maxed.
    var effectiveOpponentSpeed: CGFloat { config.opponentSpeed }

    /// Role-based defense: a few opponents mark the most dangerous teammates (cutting
    /// pass outlets) while the rest contain the carrier (engagers + a containment ring),
    /// with a mutual separation force. Difficulty ramps with the score.
    private func updateOpponentChase(_ dt: CGFloat) {
        guard !opponentsFrozen, dt > 0, let ap = activePlayer else { return }

        let aggression = min(max((CGFloat(score) - 30) / 30, 0), 1)
        let targets = opponentTargets(carrier: ap.position, aggression: aggression)
        let speed = effectiveOpponentSpeed

        for opp in opponents {
            var move = unitVector(from: opp.position, to: targets[ObjectIdentifier(opp)] ?? ap.position)
            for other in opponents where other !== opp && distance(opp.position, other.position) < config.opponentSeparation {
                let away = unitVector(from: other.position, to: opp.position)
                move.dx += away.dx
                move.dy += away.dy
            }
            let mag = hypot(move.dx, move.dy)
            if mag > 0 {
                let nx = opp.position.x + move.dx / mag * speed * dt
                let ny = opp.position.y + move.dy / mag * speed * dt
                opp.position = CGPoint(x: min(max(nx, playerSide / 2), fieldSize.width - playerSide / 2),
                                       y: min(max(ny, playerSide / 2), fieldSize.height - playerSide / 2))
            }
            if hasPossession, distance(opp.position, ap.position) < config.tackleRadius {
                registerTackle(at: ap.position)
                return
            }
        }
    }

    private func opponentTargets(carrier: CGPoint, aggression: CGFloat) -> [ObjectIdentifier: CGPoint] {
        var targets: [ObjectIdentifier: CGPoint] = [:]
        var available = opponents

        let leaveOpen = aggression >= 0.6 ? 0 : 1
        let markerCount = max(0, min(teammates.count - leaveOpen, available.count - config.minCarrierDefenders))
        if markerCount > 0 {
            let toMark = teammates
                .sorted { outletScore(for: $0, carrier: carrier) > outletScore(for: $1, carrier: carrier) }
                .prefix(markerCount)
            for mate in toMark {
                guard let nearest = available.min(by: {
                    distance($0.position, mate.position) < distance($1.position, mate.position)
                }) else { break }
                available.removeAll { $0 === nearest }
                targets[ObjectIdentifier(nearest)] = CGPoint(x: mate.position.x + config.markGoalSideOffset,
                                                             y: mate.position.y)
            }
        }

        let carrierDefenders = available.sorted {
            distance($0.position, carrier) < distance($1.position, carrier)
        }
        let engagers = min(carrierDefenders.count, aggression >= 0.5 ? 2 : 1)
        for opp in carrierDefenders.prefix(engagers) {
            targets[ObjectIdentifier(opp)] = carrier
        }

        let ringDefenders = Array(carrierDefenders.dropFirst(engagers))
        if !ringDefenders.isEmpty {
            let radius = config.surroundRadiusBase - (config.surroundRadiusBase - config.surroundRadiusMin) * aggression
            let k = ringDefenders.count
            let slots = (0..<k).map { j -> CGPoint in
                let theta = CGFloat(j) * (2 * .pi) / CGFloat(k)
                return CGPoint(x: carrier.x + cos(theta) * radius, y: carrier.y + sin(theta) * radius)
            }
            let bySlotAngle = slots.sorted { atan2($0.y - carrier.y, $0.x - carrier.x) < atan2($1.y - carrier.y, $1.x - carrier.x) }
            let byOppAngle = ringDefenders.sorted {
                atan2($0.position.y - carrier.y, $0.position.x - carrier.x) < atan2($1.position.y - carrier.y, $1.position.x - carrier.x)
            }
            for (opp, slot) in zip(byOppAngle, bySlotAngle) {
                targets[ObjectIdentifier(opp)] = slot
            }
        }

        return targets
    }

    /// How attractive a teammate is as a pass outlet — open space + progress (the
    /// progress term is sport-specific via `passProgressGain`).
    private func outletScore(for mate: SKNode, carrier: CGPoint) -> CGFloat {
        let openness = opponents
            .map { distance(mate.position, $0.position) }
            .filter { $0 > config.markGoalSideOffset * 1.3 }
            .min() ?? .greatestFiniteMagnitude
        return openness + passProgressGain(mate: mate, carrier: carrier)
    }

    /// Teammate AI: run into open lanes as pass outlets. The target X comes from a hook
    /// so AFL leads ahead while Rugby trails behind for backward support.
    private func updateTeammateMovement(_ dt: CGFloat) {
        guard dt > 0, let ap = activePlayer else { return }
        let mates = teammates
        let count = max(mates.count, 1)
        let firstLaneY = ap.position.y - CGFloat(count - 1) / 2 * config.teammateSpread

        for (i, mate) in mates.enumerated() {
            let targetX = teammateTargetX(carrierX: ap.position.x)
            let targetY = firstLaneY + CGFloat(i) * config.teammateSpread
            var move = unitVector(from: mate.position, to: CGPoint(x: targetX, y: targetY))

            for opp in opponents where distance(mate.position, opp.position) < config.teammateOpenRadius {
                let away = unitVector(from: opp.position, to: mate.position)
                move.dx += away.dx * 1.5
                move.dy += away.dy * 1.5
            }

            if distance(mate.position, ap.position) < playerSide * 2 {
                let away = unitVector(from: ap.position, to: mate.position)
                move.dx += away.dx
                move.dy += away.dy
            }

            let mag = hypot(move.dx, move.dy)
            guard mag > 0 else { continue }
            // Teammates run at the carrier's pace so they keep up and advance with the play
            // instead of trailing off the back.
            let nx = mate.position.x + move.dx / mag * config.playerSpeed * dt
            let ny = mate.position.y + move.dy / mag * config.playerSpeed * dt
            mate.position = CGPoint(x: min(max(nx, playerSide / 2), fieldSize.width - playerSide / 2),
                                    y: min(max(ny, playerSide / 2), fieldSize.height - playerSide / 2))
        }
    }

    /// Hook: the X a teammate seeks. Default = AFL (lead ahead, short of the line).
    func teammateTargetX(carrierX: CGFloat) -> CGFloat {
        min(carrierX + config.teammateLeadAhead, scoringLineX - config.teammateLineBuffer)
    }

    /// Hook: per-frame teammate appearance. Default no-op; Rugby greys out forward mates.
    func updateTeammateAppearance() {}

    /// Snap teammates into good support shape around the carrier: one per lane at the support
    /// depth (`teammateTargetX`), each shifted to the most open nearby spot. Called when play
    /// restarts (e.g. Rugby's play-the-ball) so they reset to useful positions instead of
    /// sitting wherever the tackle left them.
    func positionTeammatesForSupport() {
        guard let ap = activePlayer else { return }
        let mates = teammates
        let count = max(mates.count, 1)
        let baseX = teammateTargetX(carrierX: ap.position.x)
        let firstLaneY = ap.position.y - CGFloat(count - 1) / 2 * config.teammateSpread
        let defenders = opponents + lineDefenders

        for (i, mate) in mates.enumerated() {
            let laneY = firstLaneY + CGFloat(i) * config.teammateSpread
            mate.position = openestSpot(near: CGPoint(x: baseX, y: laneY), avoiding: defenders)
        }
    }

    /// The most open of a few candidate spots near `point` — maximises the distance to the
    /// nearest defender, clamped to the field.
    private func openestSpot(near point: CGPoint, avoiding defenders: [SKNode]) -> CGPoint {
        let step = config.teammateSpread * 0.5
        var best = clampedToField(point)
        var bestOpenness = -CGFloat.greatestFiniteMagnitude
        for dx in [-step, 0, step] {
            for dy in [-step, 0, step] {
                let p = clampedToField(CGPoint(x: point.x + dx, y: point.y + dy))
                let openness = defenders.map { distance(p, $0.position) }.min() ?? .greatestFiniteMagnitude
                if openness > bestOpenness { bestOpenness = openness; best = p }
            }
        }
        return best
    }

    private func clampedToField(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, playerSide / 2), fieldSize.width - playerSide / 2),
                y: min(max(p.y, playerSide / 2), fieldSize.height - playerSide / 2))
    }

    // MARK: - Phase: Handpass / directional aim (open play)

    /// Movement direction used to aim a pass (joystick first, else keyboard).
    private var currentMoveVector: CGVector {
        (joystickVector.dx != 0 || joystickVector.dy != 0) ? joystickVector : keyboardVector
    }

    /// The eligible teammate closest to the line projected from the carrier in `dir` — the
    /// FC-style "pass where you're pointing". Mates in front only; nil if none.
    private func directionalPassTarget(dir: CGVector) -> SKNode? {
        guard let ap = activePlayer else { return nil }
        let mag = hypot(dir.dx, dir.dy)
        guard mag > 0 else { return nil }
        let ux = dir.dx / mag, uy = dir.dy / mag
        var best: SKNode?
        var bestCost = CGFloat.greatestFiniteMagnitude
        for mate in teammates where isEligiblePassTarget(mate) {
            let rx = mate.position.x - ap.position.x
            let ry = mate.position.y - ap.position.y
            let proj = rx * ux + ry * uy
            guard proj > 0 else { continue }                  // must be in the aim direction
            let perp = abs(rx * uy - ry * ux)                 // distance to the aim line
            let cost = perp + proj * 0.1                      // tie-break: nearer along the line
            if cost < bestCost { bestCost = cost; best = mate }
        }
        return best
    }

    /// Fallback so there's always something highlighted: nearest eligible teammate.
    private func nearestEligibleTeammate() -> SKNode? {
        guard let ap = activePlayer else { return nil }
        return teammates.filter { isEligiblePassTarget($0) }
            .min { distance($0.position, ap.position) < distance($1.position, ap.position) }
    }

    /// Refreshes the highlighted pass target while carrying. Joystick aiming wins (touch);
    /// the keyboard movement vector is ignored so arrows only move — Q/E cycle instead.
    private func updatePassAim() {
        if let mate = aimedTeammate,
           !(teammates.contains { $0 === mate } && isEligiblePassTarget(mate)) {
            setAimedTeammate(nil)
        }
        if joystickVector.dx != 0 || joystickVector.dy != 0,
           let t = directionalPassTarget(dir: joystickVector) {
            setAimedTeammate(t)
        }
        if aimedTeammate == nil { setAimedTeammate(nearestEligibleTeammate()) }
    }

    /// Cycle the highlighted pass target through eligible teammates (top → bottom).
    private func cyclePassTarget(by step: Int) {
        let options = teammates.filter { isEligiblePassTarget($0) }
            .sorted { $0.position.y < $1.position.y }
        guard !options.isEmpty else { return }
        let current = options.firstIndex { $0 === aimedTeammate }
        let next = current.map { ($0 + step + options.count) % options.count } ?? (step >= 0 ? 0 : options.count - 1)
        setAimedTeammate(options[next])
    }

    /// Pass to the highlighted teammate (Pass button / Space), falling back to the
    /// directional pick then the best-scored outlet.
    func passToAimedTeammate() {
        guard hasPossession, state == .playOn else { return }
        let aimed = aimedTeammate.flatMap { isEligiblePassTarget($0) ? $0 : nil }
        guard let target = aimed ?? directionalPassTarget(dir: currentMoveVector) ?? bestPassTarget() else { return }
        handpass(to: target)
    }

    /// Keyboard Q/E: cycle the pass target while carrying, or — during the kickoff —
    /// switch the controlled player to the teammate above / below.
    func nudgeSelection(by step: Int) {
        if state == .playOn, hasPossession {
            cyclePassTarget(by: step)
        } else if state == .aerial, let ap = activePlayer {
            let options = teammates.sorted { $0.position.y < $1.position.y }
            guard !options.isEmpty else { return }
            let target = step >= 0
                ? (options.first { $0.position.y > ap.position.y } ?? options.first!)
                : (options.last { $0.position.y < ap.position.y } ?? options.last!)
            setActivePlayer(target)
        }
    }

    private func setAimedTeammate(_ mate: SKNode?) {
        guard mate !== aimedTeammate else { return }
        aimedTeammate?.childNode(withName: "passAim")?.removeFromParent()
        aimedTeammate = mate
        guard let mate else { return }
        let ring = SKShapeNode(rectOf: CGSize(width: playerSide + 12, height: playerSide + 12), cornerRadius: 8)
        ring.name = "passAim"
        ring.strokeColor = SKColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 0.9)
        ring.lineWidth = 3
        ring.fillColor = .clear
        ring.zPosition = -1
        ring.run(.repeatForever(.sequence([
            .scale(to: 1.12, duration: 0.5),
            .scale(to: 1.0, duration: 0.5)
        ])))
        mate.addChild(ring)
    }

    private func clearPassAim() {
        aimedTeammate?.childNode(withName: "passAim")?.removeFromParent()
        aimedTeammate = nil
    }

    /// Hook: may the carrier pass to this teammate? Default = always (AFL). Rugby
    /// allows only level-or-behind mates.
    func isEligiblePassTarget(_ mate: SKNode) -> Bool { true }

    /// Hook: the "progress" reward used by passing + the opponent marking AI. Default = AFL forward gain.
    func passProgressGain(mate: SKNode, carrier: CGPoint) -> CGFloat {
        (mate.position.x - carrier.x) * 0.5
    }

    /// The safest, most progressive *eligible* outlet: rewards openness + progress, and
    /// rejects tightly-marked mates or those with a defender on the pass lane.
    private func bestPassTarget() -> SKNode? {
        guard let ap = activePlayer else { return nil }
        var best: SKNode?
        var bestScore = -CGFloat.greatestFiniteMagnitude
        for mate in teammates {
            guard isEligiblePassTarget(mate) else { continue }
            let openness = opponents.map { distance(mate.position, $0.position) }.min() ?? .greatestFiniteMagnitude
            if openness < config.interceptRadius * 1.5 { continue }
            if defenderOnLane(from: ap.position, to: mate.position) { continue }
            let score = openness + passProgressGain(mate: mate, carrier: ap.position)
            if score > bestScore { bestScore = score; best = mate }
        }
        return best
    }

    private func defenderOnLane(from: CGPoint, to: CGPoint) -> Bool {
        let lane = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let laneLen = hypot(lane.dx, lane.dy)
        guard laneLen > 0 else { return false }
        for opp in opponents {
            let rel = CGVector(dx: opp.position.x - from.x, dy: opp.position.y - from.y)
            let t = (rel.dx * lane.dx + rel.dy * lane.dy) / (laneLen * laneLen)
            guard t > 0, t < 1 else { continue }
            let closest = CGPoint(x: from.x + lane.dx * t, y: from.y + lane.dy * t)
            if distance(opp.position, closest) < config.interceptRadius { return true }
        }
        return false
    }

    func handpass(to teammate: SKNode) {
        guard hasPossession, state == .playOn, let ball else { return }
        state = .passing
        passTarget = teammate
        hasPossession = false
        let dir = unitVector(from: ball.position, to: teammate.position)
        ballVelocity = CGVector(dx: dir.dx * config.handpassSpeed, dy: dir.dy * config.handpassSpeed)
    }

    /// Make `node` the controlled player without otherwise changing the phase — used to
    /// tap-switch to a better-placed teammate while chasing the kickoff.
    func setActivePlayer(_ node: SKNode) {
        guard node !== activePlayer, teammates.contains(where: { $0 === node }) else { return }
        let group = ([activePlayer] + teammates).compactMap { $0 }
        activePlayer = node
        teammates = group.filter { $0 !== node }
        refreshFriendlyRoles(group)
        centerCameraOnActive(snap: true)
    }

    private func switchControl(to teammate: SKNode) {
        setActivePlayer(teammate)
        hasPossession = true
        passTarget = nil
        ballVelocity = .zero
        state = .playOn
    }

    // MARK: - Scoring line / staged kick

    private func checkScoringLine() {
        guard hasPossession, let ap = activePlayer, ap.position.x >= scoringLineX else { return }
        didCrossScoringLine(at: ap.position)
    }

    /// Hook: the carrier crossed the scoring line. Default = AFL set shot.
    func didCrossScoringLine(at point: CGPoint) {
        beginKickPhase()
    }

    func beginKickPhase() {
        state = .kicking
        resetTouchTracking()

        let layer = SKNode()
        layer.zPosition = 50

        let bg = SKSpriteNode(color: SKColor(red: 0.12, green: 0.32, blue: 0.15, alpha: 1),
                              size: CGSize(width: fieldSize.width, height: 2400))
        bg.position = stageCenter
        layer.addChild(bg)

        let hint = SKLabelNode(text: kickHintText)
        hint.fontName = "AvenirNext-Bold"
        hint.fontSize = 70
        hint.fontColor = .white
        hint.position = CGPoint(x: stageCenter.x, y: stageCenter.y - 760)
        layer.addChild(hint)

        let shooter = SKSpriteNode(color: config.activeColor, size: CGSize(width: playerSide, height: playerSide))
        shooter.position = CGPoint(x: kickBallX, y: stageBall.y - 90)
        layer.addChild(shooter)

        buildKickStage(on: layer)

        addChild(layer)
        setShotLayer = layer

        ball?.removeAllActions()
        ball?.setScale(1.0)
        ball?.isHidden = false
        ball?.zPosition = 60
        ball?.position = CGPoint(x: kickBallX, y: stageBall.y)

        configureSetShotCamera()
    }

    /// Hook: posts (and any keeper) for the staged kick. Default = AFL 4 posts + keeper.
    func buildKickStage(on layer: SKNode) {
        for dx in [-360.0, -120.0, 120.0, 360.0] {
            let inner = abs(dx) < 200
            let post = SKSpriteNode(color: .white, size: CGSize(width: 18, height: inner ? 360 : 240))
            post.position = CGPoint(x: stageCenter.x + CGFloat(dx), y: stagePostLineY)
            layer.addChild(post)
        }
    }

    /// Hook: the kick prompt text. Default shared "swipe up to kick".
    var kickHintText: String { String(localized: "AFL_Swipe_Hint") }

    /// `power` = swipe speed, `angle` = swipe direction. Up-and-straight scores.
    func handleSwipeKick(power: CGFloat, angle: CGFloat) {
        guard state == .kicking, let ball else { return }
        let dirX = cos(angle), dirY = sin(angle)
        let minPower: CGFloat = 600

        guard dirY > 0.25, power >= minPower else {
            animateShot(to: CGPoint(x: ball.position.x, y: stagePostLineY - 250),
                        arcHeight: 110, duration: 0.5) { [weak self] in
                self?.finishKick(points: 0, labelText: nil)
            }
            return
        }

        let originX = ball.position.x
        let rise = stagePostLineY - stageBall.y
        var landingX = originX + (dirX / dirY) * rise
        if power > 2600 { landingX += CGFloat.random(in: -90...90) }
        landingX = min(max(landingX, stageCenter.x - 700), stageCenter.x + 700)

        animateShot(to: CGPoint(x: landingX, y: goalBallY),
                    arcHeight: 260, duration: 0.6) { [weak self] in
            self?.resolveKick(landingX: landingX)
        }
    }

    /// Hook: score the kick that landed at `landingX` (measured against `stageCenter.x`).
    /// Default = AFL goal(6)/behind(1).
    func resolveKick(landingX: CGFloat) {
        let dx = abs(landingX - stageCenter.x)
        if dx <= 120 {
            finishKick(points: 6, labelText: String(localized: "AFL_Goal"))
        } else if dx <= 360 {
            finishKick(points: 1, labelText: String(localized: "AFL_Behind"))
        } else {
            finishKick(points: 0, labelText: nil)
        }
    }

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
            let arc = sin(t * .pi) * arcHeight
            node.position = CGPoint(x: x, y: y + arc)
            node.setScale(1 + sin(t * .pi) * 0.8)

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
        dot.fillColor = config.ballColor.withAlphaComponent(0.45)
        dot.strokeColor = .clear
        dot.position = point
        dot.zPosition = 59
        addChild(dot)
        dot.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
    }

    /// Apply the kick result, flash the label, then move to the next possession.
    func finishKick(points: Int, labelText: String?) {
        if points > 0 { score += points }
        if let labelText { showFloatingLabel(labelText) }
        run(.wait(forDuration: 1.0)) { [weak self] in
            guard let self, self.state == .kicking else { return }
            self.beginNewPossession()
        }
    }

    // MARK: - Tackles

    /// Funnels every tackle trigger (distance + physics contact) through one guarded
    /// path so a single tackle fires the hook once.
    func registerTackle(at point: CGPoint) {
        guard hasPossession, state == .playOn, tackleCooldown <= 0 else { return }
        tackleCooldown = 0.5
        didTackleCarrier(at: point)
    }

    /// Hook: what a tackle does. Default = AFL game over.
    func didTackleCarrier(at point: CGPoint) {
        showFloatingLabel(String(localized: "AFL_Tackled"))
        triggerGameOver()
    }

    // MARK: - Pause / restart-on-touch

    /// Freezes play, shows a persistent `label`, resets the joystick, and waits for the
    /// player to lift every finger and press again before running `onResume`. Used for a
    /// deliberate restart such as Rugby's play-the-ball after a tackle.
    func pauseForRestart(label: String, onResume: @escaping () -> Void) {
        guard state == .playOn else { return }
        state = .paused
        onResumeFromPause = onResume
        resetTouchTracking()                 // drop the joystick
        resumeArmed = touchesDown.isEmpty    // if no finger is down, the next press resumes
        showHoldLabel(label)
    }

    /// Like `pauseForRestart`, but instead of resuming on the next touch it lets the player
    /// drag teammates into position and waits for an explicit `continueInteractiveRestart()`.
    /// Used by Rugby's Advanced Mode play-the-ball.
    func pauseForPositioning(label: String, onResume: @escaping () -> Void) {
        guard state == .playOn else { return }
        state = .paused
        onResumeFromPause = onResume
        resetTouchTracking()             // drop the joystick
        resumeArmed = false              // a touch drags a teammate, it never resumes play
        isInteractiveRestart = true
        showHoldLabel(label)
    }

    func continueInteractiveRestart() {
        guard state == .paused, isInteractiveRestart else { return }
        isInteractiveRestart = false
        draggedNode = nil
        resumeFromPause()
    }

    private func resumeFromPause() {
        guard state == .paused else { return }
        isInteractiveRestart = false
        draggedNode = nil
        holdLabel?.removeFromParent(); holdLabel = nil
        resumeArmed = false
        state = .playOn
        let resume = onResumeFromPause
        onResumeFromPause = nil
        resume?()
    }

    /// A centred, gently pulsing label that stays until play restarts.
    private func showHoldLabel(_ text: String) {
        holdLabel?.removeFromParent()
        let label = SKLabelNode(text: text)
        label.fontName = "AvenirNext-Heavy"
        label.fontSize = 64
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        let scale = fittedLabelScale(label, peakGrowth: 1.12)
        label.setScale(scale)
        label.zPosition = 100
        label.run(.repeatForever(.sequence([
            .scale(to: 1.12 * scale, duration: 0.5),
            .scale(to: scale, duration: 0.5)
        ])))
        cameraNode.addChild(label)
        holdLabel = label
    }

    // MARK: - Game Over

    func triggerGameOver() {
        guard state != .gameOver else { return }
        state = .gameOver
        resetTouchTracking()
        onGameOver?()
    }

    // MARK: - Touch Handling

    private func resetTouchTracking() {
        activeTouch = nil
        joystickAnchor = nil
        joystickVector = .zero
        pendingPass = nil
        removeJoystickVisual()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { touchesDown.insert(touch) }

        // Interactive restart (Advanced Mode): grab the teammate under the finger to drag it,
        // and never resume on touch — play restarts only via continueInteractiveRestart().
        if state == .paused, isInteractiveRestart {
            if let touch = touches.first {
                draggedNode = teammate(at: touch.location(in: self), requireEligible: false)
            }
            return
        }

        // Paused (e.g. play-the-ball): a fresh press, after every finger has lifted,
        // restarts play. We then fall through so that same press immediately grabs the
        // joystick — no extra tap needed to start controlling the player.
        if state == .paused {
            guard resumeArmed else { return }
            resumeFromPause()
        }

        for touch in touches {
            let location = touch.location(in: self)
            switch state {
            case .kicking:
                swipeStart = location
                swipeStartTime = touch.timestamp
            case .aerial:
                if activeTouch == nil {
                    activeTouch = touch
                    joystickAnchor = location
                    joystickVector = .zero
                    // Tap a teammate to take control of them and chase the kick — the same
                    // finger then drives them via the joystick.
                    if let mate = teammate(at: location, requireEligible: false) {
                        setActivePlayer(mate)
                    }
                    showJoystickVisual(at: location)
                } else if let mate = teammate(at: location, requireEligible: false) {
                    // Second finger while already running: switch to the tapped teammate,
                    // keep steering with the joystick finger.
                    setActivePlayer(mate)
                }
            case .playOn:
                if activeTouch == nil {
                    activeTouch = touch
                    joystickAnchor = location
                    joystickVector = .zero
                    pendingPass = hasPossession ? teammate(at: location) : nil
                    if pendingPass == nil { showJoystickVisual(at: location) }
                } else if hasPossession {
                    if let target = teammate(at: location) ?? bestPassTarget() {
                        handpass(to: target)
                    }
                }
            case .passing, .paused, .gameOver:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if state == .paused, isInteractiveRestart {
            if let mate = draggedNode, let touch = touches.first {
                mate.position = clampedToField(touch.location(in: self))
            }
            return
        }
        if state == .kicking { return }
        guard let touch = touches.first(where: { $0 === activeTouch }),
              let anchor = joystickAnchor else { return }
        let location = touch.location(in: self)

        let delta = CGVector(dx: location.x - anchor.x, dy: location.y - anchor.y)
        let mag = hypot(delta.dx, delta.dy)
        let deadzone: CGFloat = 28
        let passCancelDistance: CGFloat = 120

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
        for touch in touches { touchesDown.remove(touch) }

        // Interactive restart: lifting a finger just drops the dragged teammate; play resumes
        // only via the Continue button (continueInteractiveRestart).
        if state == .paused, isInteractiveRestart {
            draggedNode = nil
            return
        }

        // Arm the restart once the screen is clear of fingers.
        if state == .paused {
            if touchesDown.isEmpty { resumeArmed = true }
            return
        }

        if state == .kicking {
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
        for touch in touches { touchesDown.remove(touch) }

        if state == .paused, isInteractiveRestart {
            draggedNode = nil
            return
        }

        if state == .paused {
            if touchesDown.isEmpty { resumeArmed = true }
            return
        }

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

    /// Nearest teammate to a tap. `requireEligible` keeps it to legal pass outlets (for
    /// passing); kickoff control-switching passes `false` so any teammate can be picked.
    private func teammate(at point: CGPoint, requireEligible: Bool = true) -> SKNode? {
        let pool = requireEligible ? teammates.filter { isEligiblePassTarget($0) } : teammates
        let hits = nodes(at: point)
        if let direct = pool.first(where: { mate in hits.contains { $0 === mate || $0.parent === mate } }) {
            return direct
        }
        return pool
            .map { ($0, distance(point, $0.position)) }
            .filter { $0.1 <= config.passTapRadius }
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
        if tackleCooldown > 0 { tackleCooldown -= TimeInterval(dt) }

        switch state {
        case .aerial:
            applyJoystick(dt)
            let p = updateAerialFlight(dt)
            if let ap = activePlayer, airborne,
               p >= config.catchWindowStart,
               distance(ap.position, ballGround) < config.markRadius {
                handleAerialCatch(by: ap)
            } else if p >= 1 {
                airborne = false
                removeLandingMarker()
                onAerialLanded(at: ballGround)
            }

        case .playOn:
            applyJoystick(dt)
            if hasPossession {
                attachBallToCarrier()
                updateTeammateMovement(dt)
                updateTeammateAppearance()
                updatePassAim()
                updateOpponentChase(dt)
                updateLineDefenders(dt)
                checkScoringLine()
            } else if let ap = activePlayer, let b = ball, distance(ap.position, b.position) < config.pickupRadius {
                gainPossession(by: ap)
            }

        case .passing:
            moveBall(dt)
            updateOpponentChase(dt)
            updateLineDefenders(dt)
            if let b = ball {
                for opp in opponents where distance(opp.position, b.position) < config.interceptRadius {
                    showFloatingLabel(String(localized: "AFL_Intercepted"))
                    triggerGameOver()
                    return
                }
                if let target = passTarget, distance(b.position, target.position) < config.arriveRadius {
                    switchControl(to: target)
                }
            }

        case .kicking, .paused, .gameOver:
            break
        }

        // The pass-target highlight only exists while carrying the ball in open play
        // (never during the kickoff).
        if !(state == .playOn && hasPossession) { clearPassAim() }

        switch state {
        case .aerial, .playOn, .passing:
            centerCameraOnActive(snap: false)
        case .kicking, .paused, .gameOver:
            break
        }
    }

    func setKeyboardDirection(_ v: CGVector) { keyboardVector = v }

    private func applyJoystick(_ dt: CGFloat) {
        let move = (joystickVector.dx != 0 || joystickVector.dy != 0) ? joystickVector : keyboardVector
        guard dt > 0, let ap = activePlayer, move.dx != 0 || move.dy != 0 else { return }
        let speed = config.playerSpeed * (state == .aerial ? aerialPlayerSpeedFactor : 1)
        let nx = ap.position.x + move.dx * speed * dt
        let ny = ap.position.y + move.dy * speed * dt
        ap.position = CGPoint(x: min(max(nx, playerSide / 2), fieldSize.width - playerSide / 2),
                              y: min(max(ny, playerSide / 2), fieldSize.height - playerSide / 2))
    }

    private func moveBall(_ dt: CGFloat) {
        guard dt > 0, let b = ball else { return }
        b.position = CGPoint(x: b.position.x + ballVelocity.dx * dt,
                             y: b.position.y + ballVelocity.dy * dt)
    }

    private func updateAerialFlight(_ dt: CGFloat) -> CGFloat {
        guard dt > 0, let b = ball, flightDuration > 0 else { return 0 }
        flightElapsed += dt
        let p = max(0, min(1, flightElapsed / flightDuration))
        ballGround = CGPoint(x: flightStart.x + (flightEnd.x - flightStart.x) * p,
                             y: flightStart.y + (flightEnd.y - flightStart.y) * p)
        // One parabolic arc (0 → 1 → 0) drives both height and size: the ball rises toward
        // the overhead camera (grows), peaks at mid-flight, then falls back down (shrinks).
        let arc = sin(p * .pi)
        let lift = arc * config.aerialArcHeight
        let scale = config.minFlightScale + (config.maxFlightScale - config.minFlightScale) * arc
        b.position = CGPoint(x: ballGround.x, y: ballGround.y + lift)
        b.setScale(scale)
        return p
    }

    private func attachBallToCarrier() {
        guard let ap = activePlayer, let b = ball else { return }
        b.position = CGPoint(x: ap.position.x + 36, y: ap.position.y)
    }

    // MARK: - Camera

    private func configureFieldCamera() {
        guard size.height > 0 else { return }
        cameraNode.setScale(config.worldVisibleHeight / size.height)
    }

    private func configureSetShotCamera() {
        guard size.height > 0 else { return }
        cameraNode.setScale(config.setShotVisibleHeight / size.height)
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

    func showFloatingLabel(_ text: String) {
        let label = SKLabelNode(text: text)
        label.fontName = "AvenirNext-Heavy"
        label.fontSize = 64
        label.fontColor = .white
        let scale = fittedLabelScale(label, peakGrowth: 1.3)
        label.setScale(scale)
        label.position = CGPoint(x: 0, y: size.height * 0.28)
        label.zPosition = 100
        cameraNode.addChild(label)
        label.run(.sequence([
            .group([.scale(to: 1.3 * scale, duration: 0.5), .fadeOut(withDuration: 1.0)]),
            .removeFromParent()
        ]))
    }

    /// Scale for a centred on-screen label. Camera children live in point/screen space and
    /// are NOT affected by the camera's scale, so the base is 1 (font points = screen
    /// points). It's reduced only if the word would render wider than ~90% of the view, to
    /// keep long / localized text fully on screen. `peakGrowth` reserves headroom for a
    /// label that scales up during its animation so it stays on screen at the peak too.
    private func fittedLabelScale(_ label: SKLabelNode, peakGrowth: CGFloat = 1.0) -> CGFloat {
        let naturalWidth = label.frame.width          // width at scale 1, in points
        let maxWidth = size.width * 0.9 / peakGrowth
        guard naturalWidth > maxWidth, naturalWidth > 0 else { return 1 }
        return maxWidth / naturalWidth
    }

    func whistleFeedback() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        let flash = SKSpriteNode(color: SKColor.white.withAlphaComponent(0.45),
                                 size: CGSize(width: size.width, height: size.height))
        flash.zPosition = 99
        cameraNode.addChild(flash)
        flash.run(.sequence([.fadeOut(withDuration: 0.35), .removeFromParent()]))
    }

    // MARK: - Vector math

    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    func randomPoint(xIn xr: ClosedRange<CGFloat>, yIn yr: ClosedRange<CGFloat>) -> CGPoint {
        CGPoint(x: .random(in: xr), y: .random(in: yr))
    }

    func unitVector(from: CGPoint, to: CGPoint) -> CGVector {
        let dx = to.x - from.x, dy = to.y - from.y
        let mag = hypot(dx, dy)
        return mag == 0 ? .zero : CGVector(dx: dx / mag, dy: dy / mag)
    }
}

// MARK: - Physics Contacts (backup to the distance checks above)

extension BaseGameScene: SKPhysicsContactDelegate {
    func didBegin(_ contact: SKPhysicsContact) {
        let mask = contact.bodyA.categoryBitMask | contact.bodyB.categoryBitMask
        switch mask {
        case PhysicsCategory.player | PhysicsCategory.opponent:
            if let ap = activePlayer { registerTackle(at: ap.position) }
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
