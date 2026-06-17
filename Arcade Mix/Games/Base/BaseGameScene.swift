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
    var opponents: [SKNode] = []
    var ball: SKNode?
    private(set) var hasPossession: Bool = false

    // MARK: - Scoring

    private(set) var score: Int = 0 {
        didSet { onScoreChanged?(score) }
    }
    func addScore(_ n: Int) { score += n }

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

    // MARK: - Swipe tracking (staged kick)

    private var swipeStart: CGPoint?
    private var swipeStartTime: TimeInterval?

    // MARK: - Pause / restart-on-touch

    private var touchesDown = Set<UITouch>()   // every finger currently on screen
    private var resumeArmed = false            // true once all fingers have lifted since pausing
    private var onResumeFromPause: (() -> Void)?
    private weak var holdLabel: SKNode?

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
        (([activePlayer, ball] + teammates + opponents).compactMap { $0 }).forEach { $0.removeFromParent() }
        setShotLayer?.removeFromParent(); setShotLayer = nil
        holdLabel?.removeFromParent(); holdLabel = nil
        onResumeFromPause = nil
        resumeArmed = false
        touchesDown.removeAll()
        removeJoystickVisual()

        teammates.removeAll()
        opponents.removeAll()
        hasPossession = false
        opponentsFrozen = false
        score = 0

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

    /// Reposition (without recreating) for the next possession after a staged kick.
    func beginNewPossession() {
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
    }

    /// Hook: set `flightStart` / `flightEnd` for the kicked-in ball. Default = AFL
    /// (kicked from the back-left toward midfield).
    func configureKickoffFlight() {
        let startY = CGFloat.random(in: margin...(fieldSize.height - margin))
        let targetX: CGFloat = .random(in: 1600...2000)
        let targetY: CGFloat = .random(in: margin...(fieldSize.height - margin))
        flightStart = CGPoint(x: 150, y: startY)
        flightEnd = CGPoint(x: targetX, y: targetY)
    }

    /// Common cleanup before the catch hook fires.
    private func handleAerialCatch(by node: SKNode) {
        airborne = false
        ballVelocity = .zero
        ball?.removeAllActions(); ball?.setScale(1.0)
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
        // A wall of defenders on the scoring line, ahead of the player. Count grows with
        // the score: 4, then +1 every 6 points (capped).
        let count = min(config.startingDefenders + score / 6, config.maxDefenders)
        let usableHeight = fieldSize.height - 2 * margin
        for i in 0..<count {
            let y = margin + (CGFloat(i) + 0.5) * usableHeight / CGFloat(count)
            let opp = makeOpponent(at: CGPoint(x: scoringLineX, y: y))
            addChild(opp)
            opponents.append(opp)
        }
    }

    func freezeOpponents() { opponentsFrozen = true }

    /// Role-based defense: a few opponents mark the most dangerous teammates (cutting
    /// pass outlets) while the rest contain the carrier (engagers + a containment ring),
    /// with a mutual separation force. Difficulty ramps with the score.
    private func updateOpponentChase(_ dt: CGFloat) {
        guard !opponentsFrozen, dt > 0, let ap = activePlayer else { return }

        let aggression = min(max((CGFloat(score) - 30) / 30, 0), 1)
        let targets = opponentTargets(carrier: ap.position, aggression: aggression)

        for opp in opponents {
            var move = unitVector(from: opp.position, to: targets[ObjectIdentifier(opp)] ?? ap.position)
            for other in opponents where other !== opp && distance(opp.position, other.position) < config.opponentSeparation {
                let away = unitVector(from: other.position, to: opp.position)
                move.dx += away.dx
                move.dy += away.dy
            }
            let mag = hypot(move.dx, move.dy)
            if mag > 0 {
                let nx = opp.position.x + move.dx / mag * config.opponentSpeed * dt
                let ny = opp.position.y + move.dy / mag * config.opponentSpeed * dt
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
            let nx = mate.position.x + move.dx / mag * config.teammateSpeed * dt
            let ny = mate.position.y + move.dy / mag * config.teammateSpeed * dt
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

    // MARK: - Phase: Handpass

    func passToBestTeammate() {
        guard hasPossession, state == .playOn, let best = bestPassTarget() else { return }
        handpass(to: best)
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

    /// Hook: may the carrier pass to this teammate? Default = always (AFL). Rugby
    /// allows only level-or-behind mates.
    func isEligiblePassTarget(_ mate: SKNode) -> Bool { true }

    /// Hook: the "progress" reward for a pass outlet. Default = AFL forward gain.
    func passProgressGain(mate: SKNode, carrier: CGPoint) -> CGFloat {
        (mate.position.x - carrier.x) * 0.5
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

    private func resumeFromPause() {
        guard state == .paused else { return }
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
        label.setScale(cameraNode.xScale)
        label.zPosition = 100
        label.run(.repeatForever(.sequence([
            .scale(to: 1.12 * cameraNode.xScale, duration: 0.5),
            .scale(to: cameraNode.xScale, duration: 0.5)
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
            case .aerial, .playOn:
                if activeTouch == nil {
                    activeTouch = touch
                    joystickAnchor = location
                    joystickVector = .zero
                    pendingPass = (hasPossession && state == .playOn) ? teammate(at: location) : nil
                    if pendingPass == nil { showJoystickVisual(at: location) }
                } else if hasPossession, state == .playOn {
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

    private func teammate(at point: CGPoint) -> SKNode? {
        let hits = nodes(at: point)
        if let direct = teammates.first(where: { mate in
            isEligiblePassTarget(mate) && hits.contains { $0 === mate || $0.parent === mate }
        }) {
            return direct
        }
        return teammates
            .filter { isEligiblePassTarget($0) }
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
                onAerialLanded(at: ballGround)
            }

        case .playOn:
            applyJoystick(dt)
            if hasPossession {
                attachBallToCarrier()
                updateTeammateMovement(dt)
                updateTeammateAppearance()
                updateOpponentChase(dt)
                checkScoringLine()
            } else if let ap = activePlayer, let b = ball, distance(ap.position, b.position) < config.pickupRadius {
                gainPossession(by: ap)
            }

        case .passing:
            moveBall(dt)
            updateOpponentChase(dt)
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
        let nx = ap.position.x + move.dx * config.playerSpeed * dt
        let ny = ap.position.y + move.dy * config.playerSpeed * dt
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
        let lift = sin(p * .pi) * config.aerialArcHeight
        let scale = config.minFlightScale + (config.maxFlightScale - config.minFlightScale) * p
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
        label.setScale(cameraNode.xScale)
        label.position = CGPoint(x: 0, y: size.height * 0.28 * cameraNode.yScale)
        label.zPosition = 100
        cameraNode.addChild(label)
        label.run(.sequence([
            .group([.scale(to: 1.3 * cameraNode.xScale, duration: 0.5), .fadeOut(withDuration: 1.0)]),
            .removeFromParent()
        ]))
    }

    func whistleFeedback() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        let flash = SKSpriteNode(color: SKColor.white.withAlphaComponent(0.45),
                                 size: CGSize(width: size.width * cameraNode.xScale,
                                              height: size.height * cameraNode.yScale))
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
