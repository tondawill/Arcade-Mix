//
//  BrickBreakerScene.swift
//  Arcade Mix
//
//  Standalone Brick Breaker engine (does NOT use the sport `BaseGameScene`). A small
//  state machine drives serve → play → level-clear / game-over. Everything is drawn
//  from basic `SKShapeNode` rectangles (paddle, bricks) and a circle (ball) — no
//  sprites yet, so the pure logic can be tested first.
//
//  The logical layout lives in a `BrickGrid` value (generation, colour-chain flood
//  fill, hit resolution); this scene mirrors it with nodes parented under one
//  `brickContainer` so the "Decline & Crunch" descent moves the whole wall as a unit
//  while the model's coordinates stay fixed.
//

import SpriteKit
import UIKit

final class BrickBreakerScene: SKScene {

    // MARK: - Config / state

    private let config: BrickBreakerConfig

    private(set) var state: BrickBreakerState = .serving
    private var difficultyFactor: CGFloat = 0.1
    private var grid = BrickGrid.generate(difficultyFactor: 0.1, columns: 7, maxRows: 9)

    private(set) var score = 0 { didSet { onScoreChanged?(score) } }
    private(set) var lives = 3 { didSet { onLivesChanged?(lives) } }
    /// 1-based level, shown in the HUD. Mirrors `difficultyFactor` (lvl = factor*10).
    private var level: Int { Int((difficultyFactor * 10).rounded()) }

    // Callbacks to the SwiftUI HUD (same pattern as BaseGameScene).
    var onScoreChanged: ((Int) -> Void)?
    var onLivesChanged: ((Int) -> Void)?
    var onLevelChanged: ((Int) -> Void)?
    var onGameOver: (() -> Void)?

    // MARK: - Nodes

    private var paddle: SKShapeNode!
    private let brickContainer = SKNode()
    private var balls: [SKShapeNode] = []
    private var brickNodes: [BrickCoord: SKShapeNode] = [:]
    private var redFields: [SKShapeNode] = []

    // MARK: - Live tuning

    private var paddleWidth: CGFloat = 92
    private var chainModeActive = false
    private var ballSpeedMultiplier: CGFloat = 1   // lowered by the Slow-ball power-up
    private var lastUpdateTime: TimeInterval = 0

    private static let crunchActionKey = "crunch"
    private static let chainKey = "powerup.chain"
    private static let wideKey = "powerup.wide"
    private static let slowKey = "powerup.slow"

    // MARK: - Init

    init(size: CGSize, config: BrickBreakerConfig = .default) {
        self.config = config
        self.paddleWidth = config.paddleSize.width
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = config.backgroundColor
        physicsWorld.gravity = .zero
        physicsWorld.contactDelegate = self
        if brickContainer.parent == nil { addChild(brickContainer) }
        buildWalls()
        buildPaddle()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        buildWalls()
        if paddle != nil { layoutPaddle() }
        layoutBricks()
    }

    /// Entry point from the model (start / restart).
    func startGame() {
        difficultyFactor = 0.1
        score = 0
        lives = config.startingLives
        onLevelChanged?(level)
        loadLevel()
    }

    // MARK: - Walls (left / top / right; bottom open so a miss is detectable)

    private func buildWalls() {
        childNode(withName: "walls")?.removeFromParent()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: size.width, y: 0))
        let walls = SKNode()
        walls.name = "walls"
        let body = SKPhysicsBody(edgeChainFrom: path)
        body.categoryBitMask = BBPhysicsCategory.wall
        body.friction = 0
        body.restitution = 1
        walls.physicsBody = body
        addChild(walls)
    }

    // MARK: - Paddle

    private func buildPaddle() {
        let node = SKShapeNode(rectOf: config.paddleSize, cornerRadius: config.paddleSize.height / 2)
        node.fillColor = config.paddleColor
        node.strokeColor = .clear
        node.zPosition = 5
        addChild(node)
        paddle = node
        setPaddleWidth(config.paddleSize.width)
        layoutPaddle()
    }

    private func layoutPaddle() {
        paddle.position = CGPoint(x: size.width / 2, y: paddleY)
    }

    private var paddleY: CGFloat { config.bottomSafeInset + config.paddleBottomInset + config.paddleSize.height / 2 }

    /// Rebuild the paddle's shape + physics body at a new width (used by the Wide power-up).
    private func setPaddleWidth(_ width: CGFloat) {
        paddleWidth = width
        let size = CGSize(width: width, height: config.paddleSize.height)
        paddle.path = CGPath(roundedRect: CGRect(x: -width / 2, y: -size.height / 2,
                                                 width: width, height: size.height),
                             cornerWidth: size.height / 2, cornerHeight: size.height / 2,
                             transform: nil)
        let body = SKPhysicsBody(rectangleOf: size)
        body.isDynamic = false
        body.friction = 0
        body.restitution = 1
        body.categoryBitMask = BBPhysicsCategory.paddle
        body.contactTestBitMask = BBPhysicsCategory.ball | BBPhysicsCategory.powerUp
        paddle.physicsBody = body
    }

    private func clampPaddleX(_ x: CGFloat) -> CGFloat {
        let half = paddleWidth / 2
        let minX = config.sideInset + half
        let maxX = size.width - config.sideInset - half
        guard minX <= maxX else { return size.width / 2 }
        return min(max(x, minX), maxX)
    }

    // MARK: - Level / brick layout

    private func loadLevel() {
        removeAction(forKey: Self.crunchActionKey)
        clearPowerUpEffects()
        grid = BrickGrid.generate(difficultyFactor: difficultyFactor,
                                  columns: config.columns, maxRows: config.maxRows)
        brickContainer.removeAllChildren()
        brickContainer.position = .zero
        brickNodes.removeAll()
        for coord in grid.occupiedCoords {
            guard let brick = grid.brick(at: coord) else { continue }
            let node = makeBrickNode(brick)
            brickContainer.addChild(node)
            brickNodes[coord] = node
        }
        layoutBricks()

        clearBalls()
        clearTokensAndFields()
        serveBall()

        // "Decline & Crunch" only engages once the difficulty has ramped past the gate.
        if difficultyFactor > config.crunchActivationFactor {
            let step = (config.brickHeight + config.brickGap) / 2
            let crunch = SKAction.sequence([
                .wait(forDuration: config.crunchInterval),
                .run { [weak self] in self?.crunchDown(by: step) }
            ])
            run(.repeatForever(crunch), withKey: Self.crunchActionKey)
        }
    }

    private var brickWidth: CGFloat { config.brickWidth(forSceneWidth: size.width) }

    /// Local position of a brick's centre within `brickContainer`.
    private func brickPosition(_ coord: BrickCoord) -> CGPoint {
        let w = brickWidth
        let x = config.sideInset + CGFloat(coord.col) * (w + config.brickGap) + w / 2
        let topY = size.height - config.topSafeInset - config.gridTopInset
        let y = topY - CGFloat(coord.row) * (config.brickHeight + config.brickGap) - config.brickHeight / 2
        return CGPoint(x: x, y: y)
    }

    private func layoutBricks() {
        let w = brickWidth
        for (coord, node) in brickNodes {
            node.position = brickPosition(coord)
            node.path = brickPath(width: w)
        }
    }

    private func brickPath(width: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: -width / 2, y: -config.brickHeight / 2,
                                   width: width, height: config.brickHeight),
               cornerWidth: 3, cornerHeight: 3, transform: nil)
    }

    private func makeBrickNode(_ brick: Brick) -> SKShapeNode {
        let node = SKShapeNode(path: brickPath(width: brickWidth))
        applyBrickStyle(node, brick)
        node.zPosition = 2
        let body = SKPhysicsBody(rectangleOf: CGSize(width: brickWidth, height: config.brickHeight))
        body.isDynamic = false
        body.friction = 0
        body.restitution = 1
        body.categoryBitMask = BBPhysicsCategory.brick
        body.contactTestBitMask = BBPhysicsCategory.ball
        node.physicsBody = body
        return node
    }

    /// Colour + outline for a brick's current state. Strong bricks darken per hit;
    /// hazard bricks use a dark-red fill with a bright outline so they read apart from
    /// a plain red brick.
    private func applyBrickStyle(_ node: SKShapeNode, _ brick: Brick) {
        node.strokeColor = .clear
        node.lineWidth = 0
        switch brick.type {
        case .basic:
            node.fillColor = brick.color.fill
        case .strong:
            let t = CGFloat(brick.hitsRemaining) / CGFloat(max(brick.maxHits, 1))
            node.fillColor = config.strongColor.scaledBrightness(0.45 + 0.55 * t)
        case .titanium:
            node.fillColor = config.titaniumColor
            node.strokeColor = SKColor.white.withAlphaComponent(0.35)
            node.lineWidth = 1.5
        case .hazard:
            node.fillColor = config.hazardColor
            node.strokeColor = SKColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 0.9)
            node.lineWidth = 2
        case .powerup:
            node.fillColor = config.powerupBrickColor
            node.strokeColor = SKColor.white.withAlphaComponent(0.6)
            node.lineWidth = 2
        }
    }

    // MARK: - Ball serving / launch

    private func makeBall(at point: CGPoint) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: config.ballRadius)
        node.fillColor = config.ballColor
        node.strokeColor = .clear
        node.position = point
        node.zPosition = 6
        let body = SKPhysicsBody(circleOfRadius: config.ballRadius)
        body.affectedByGravity = false
        body.friction = 0
        body.restitution = 1
        body.linearDamping = 0
        body.angularDamping = 0
        body.allowsRotation = false
        body.categoryBitMask = BBPhysicsCategory.ball
        body.collisionBitMask = BBPhysicsCategory.wall | BBPhysicsCategory.brick | BBPhysicsCategory.paddle
        body.contactTestBitMask = BBPhysicsCategory.brick | BBPhysicsCategory.paddle
        node.physicsBody = body
        return node
    }

    /// Park a single ball on the paddle and wait for the player to launch it.
    private func serveBall() {
        clearBalls()
        state = .serving
        let ball = makeBall(at: ballRestPosition)
        ball.physicsBody?.isDynamic = false
        addChild(ball)
        balls = [ball]
    }

    private var ballRestPosition: CGPoint {
        CGPoint(x: paddle?.position.x ?? size.width / 2,
                y: paddleY + config.paddleSize.height / 2 + config.ballRadius + 1)
    }

    private func launchBall() {
        guard state == .serving, let ball = balls.first else { return }
        state = .playing
        ball.physicsBody?.isDynamic = true
        // Launch up with a small random sideways lean.
        let lean = CGFloat.random(in: -0.35...0.35)
        let dir = CGVector(dx: lean, dy: 1)
        setBallVelocity(ball, direction: dir)
    }

    private func clearBalls() {
        balls.forEach { $0.removeFromParent() }
        balls.removeAll()
    }

    /// Drive a ball at the current baseline speed in `direction` (need not be unit).
    private func setBallVelocity(_ ball: SKShapeNode, direction: CGVector) {
        let mag = hypot(direction.dx, direction.dy)
        guard mag > 0 else { return }
        let speed = baselineSpeed
        ball.physicsBody?.velocity = CGVector(dx: direction.dx / mag * speed,
                                              dy: direction.dy / mag * speed)
    }

    private var baselineSpeed: CGFloat { config.ballSpeed * ballSpeedMultiplier }

    // MARK: - Touch input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        movePaddle(to: touch.location(in: self).x)
        if state == .serving { launchBall() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        movePaddle(to: touch.location(in: self).x)
    }

    private func movePaddle(to x: CGFloat) {
        guard paddle != nil else { return }
        paddle.position.x = clampPaddleX(x)
        if state == .serving { balls.first?.position = ballRestPosition }
    }

    /// Keyboard nudge for Simulator testing (A/D or arrows feed a signed delta).
    func nudgePaddle(_ dx: CGFloat) {
        guard paddle != nil else { return }
        movePaddle(to: paddle.position.x + dx)
    }

    func launchFromKeyboard() { if state == .serving { launchBall() } }

    // MARK: - Update loop

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdateTime == 0 ? 0 : min(currentTime - lastUpdateTime, 1.0 / 30.0)
        lastUpdateTime = currentTime

        switch state {
        case .serving:
            balls.first?.position = ballRestPosition
        case .playing:
            updateBalls(dt)
        case .levelCleared, .gameOver:
            break
        }
    }

    private func updateBalls(_ dt: TimeInterval) {
        // Remove balls that fell past the open bottom.
        var survivors: [SKShapeNode] = []
        for ball in balls {
            if ball.position.y < -config.ballRadius * 2 {
                ball.removeFromParent()
            } else {
                survivors.append(ball)
            }
        }
        balls = survivors

        if balls.isEmpty {
            loseLife()
            return
        }

        // Keep every ball at its target speed (energy-stable bounces), damped inside a
        // Red Field, and never trapped on a near-horizontal path.
        for ball in balls {
            guard let body = ball.physicsBody else { continue }
            let inField = redFields.contains { $0.frame.contains(ball.position) }
            let target = baselineSpeed * (inField ? config.redFieldDamp : 1)
            var v = body.velocity
            var mag = hypot(v.dx, v.dy)
            if mag == 0 { v = CGVector(dx: 0, dy: target); mag = target }
            // Avoid a stuck horizontal glide.
            let minVertical = target * 0.20
            if abs(v.dy) < minVertical {
                v.dy = (v.dy >= 0 ? 1 : -1) * minVertical
                mag = hypot(v.dx, v.dy)
            }
            body.velocity = CGVector(dx: v.dx / mag * target, dy: v.dy / mag * target)
        }
    }

    // MARK: - Life / level transitions

    private func loseLife() {
        guard state == .playing else { return }
        lives -= 1
        if lives <= 0 {
            triggerGameOver()
        } else {
            serveBall()
        }
    }

    private func advanceLevel() {
        state = .levelCleared
        removeAction(forKey: Self.crunchActionKey)
        difficultyFactor += 0.1
        onLevelChanged?(level)
        run(.sequence([.wait(forDuration: 1.0), .run { [weak self] in self?.loadLevel() }]))
    }

    private func triggerGameOver() {
        guard state != .gameOver else { return }
        state = .gameOver
        removeAction(forKey: Self.crunchActionKey)
        onGameOver?()
    }

    // MARK: - "Decline & Crunch"

    private func crunchDown(by step: CGFloat) {
        guard state == .playing || state == .serving else { return }
        brickContainer.run(.moveBy(x: 0, y: -step, duration: 0.3))
        // Defer the threshold test until the slide finishes.
        run(.sequence([.wait(forDuration: 0.32), .run { [weak self] in self?.checkCrunchGameOver() }]))
    }

    private func checkCrunchGameOver() {
        guard state == .playing || state == .serving else { return }
        guard let lowestRow = grid.lowestOccupiedRow else { return }
        // Absolute bottom edge of the lowest brick after the container's descent.
        let localBottom = brickPosition(BrickCoord(row: lowestRow, col: 0)).y - config.brickHeight / 2
        let absoluteBottom = brickContainer.position.y + localBottom
        let paddleTop = paddleY + config.paddleSize.height / 2
        if absoluteBottom <= paddleTop + config.ballRadius * 2 {
            triggerGameOver()
        }
    }

    // MARK: - Brick hits

    private func handleBallBrickContact(ball: SKShapeNode, brickNode: SKShapeNode) {
        guard let coord = coord(of: brickNode), let brick = grid.brick(at: coord) else { return }

        // Colour-chain: a chain-armed ball striking a basic brick shatters the whole
        // connected same-colour cluster via the flood fill (Connect 4 grid logic).
        if chainModeActive, brick.isChainable {
            let cluster = grid.floodFillSameColor(from: coord)
            for c in cluster {
                grid.removeBrick(at: c)
                destroyBrickNode(at: c, chained: true)
                score += 10
            }
            checkLevelCleared()
            return
        }

        switch grid.hit(at: coord) {
        case .empty, .indestructible:
            break
        case .damaged(let updated):
            applyBrickStyle(brickNode, updated)
        case .destroyed(let destroyed):
            destroyBrickNode(at: coord, chained: false)
            score += 10
            switch destroyed.type {
            case .hazard:  spawnRedField(at: coord)
            case .powerup: dropPowerUp(at: coord)
            default: break
            }
            checkLevelCleared()
        }
    }

    private func coord(of node: SKNode) -> BrickCoord? {
        brickNodes.first(where: { $0.value === node })?.key
    }

    private func destroyBrickNode(at coord: BrickCoord, chained: Bool) {
        guard let node = brickNodes.removeValue(forKey: coord) else { return }
        node.physicsBody = nil
        let pop = SKAction.group([.scale(to: chained ? 1.4 : 1.2, duration: 0.12),
                                  .fadeOut(withDuration: 0.12)])
        node.run(.sequence([pop, .removeFromParent()]))
    }

    private func checkLevelCleared() {
        if grid.isCleared, state == .playing { advanceLevel() }
    }

    // MARK: - Red Field hazard

    private func spawnRedField(at coord: BrickCoord) {
        let w = brickWidth
        let field = SKShapeNode(rectOf: CGSize(width: w, height: config.brickHeight), cornerRadius: 3)
        field.fillColor = config.redFieldColor
        field.strokeColor = .clear
        // Placed in scene space at the brick's current absolute position (non-solid, no body).
        field.position = CGPoint(x: brickContainer.position.x + brickPosition(coord).x,
                                 y: brickContainer.position.y + brickPosition(coord).y)
        field.zPosition = 1
        addChild(field)
        redFields.append(field)
        field.run(.sequence([
            .wait(forDuration: config.redFieldDuration - 0.6),
            .fadeOut(withDuration: 0.6),
            .removeFromParent()
        ])) { [weak self] in
            self?.redFields.removeAll { $0 === field }
        }
    }

    // MARK: - Power-ups

    private func dropPowerUp(at coord: BrickCoord) {
        let kind = PowerUpKind.allCases.randomElement()!
        let token = SKShapeNode(rectOf: CGSize(width: 22, height: 14), cornerRadius: 4)
        token.fillColor = kind.color
        token.strokeColor = .clear
        token.zPosition = 4
        token.position = CGPoint(x: brickContainer.position.x + brickPosition(coord).x,
                                 y: brickContainer.position.y + brickPosition(coord).y)

        let label = SKLabelNode(text: kind.glyph)
        label.fontName = "AvenirNext-Bold"
        label.fontSize = 11
        label.fontColor = .black
        label.verticalAlignmentMode = .center
        token.addChild(label)

        let body = SKPhysicsBody(rectangleOf: CGSize(width: 22, height: 14))
        body.affectedByGravity = false
        body.linearDamping = 0
        body.categoryBitMask = BBPhysicsCategory.powerUp
        body.collisionBitMask = 0
        body.contactTestBitMask = BBPhysicsCategory.paddle
        token.physicsBody = body
        token.physicsBody?.velocity = CGVector(dx: 0, dy: -140)
        token.userData = ["kind": kind.encoded]
        addChild(token)
    }

    private func collectPowerUp(_ token: SKNode) {
        guard let raw = token.userData?["kind"] as? Int, let kind = PowerUpKind(encoded: raw) else {
            token.removeFromParent(); return
        }
        token.removeFromParent()
        apply(kind)
    }

    private func apply(_ kind: PowerUpKind) {
        switch kind {
        case .chain:
            chainModeActive = true
            removeAction(forKey: Self.chainKey)
            run(.sequence([.wait(forDuration: config.chainDuration),
                           .run { [weak self] in self?.chainModeActive = false }]),
                withKey: Self.chainKey)
        case .multiBall:
            spawnExtraBalls()
        case .widePaddle:
            setPaddleWidth(config.paddleSize.width * config.widePaddleScale)
            removeAction(forKey: Self.wideKey)
            run(.sequence([.wait(forDuration: config.widePaddleDuration),
                           .run { [weak self] in
                               guard let self else { return }
                               self.setPaddleWidth(self.config.paddleSize.width)
                               self.paddle.position.x = self.clampPaddleX(self.paddle.position.x)
                           }]),
                withKey: Self.wideKey)
        case .slowBall:
            ballSpeedMultiplier = config.slowBallFactor
            removeAction(forKey: Self.slowKey)
            run(.sequence([.wait(forDuration: config.slowBallDuration),
                           .run { [weak self] in self?.ballSpeedMultiplier = 1 }]),
                withKey: Self.slowKey)
        }
    }

    /// Multi-ball: give each live ball a mirrored partner, capped so the scene stays sane.
    private func spawnExtraBalls() {
        guard state == .playing else { return }
        let maxBalls = 6
        for ball in balls where balls.count < maxBalls {
            let extra = makeBall(at: ball.position)
            addChild(extra)
            let v = ball.physicsBody?.velocity ?? CGVector(dx: 0, dy: baselineSpeed)
            setBallVelocity(extra, direction: CGVector(dx: -v.dx, dy: abs(v.dy)))
            balls.append(extra)
        }
    }

    private func clearPowerUpEffects() {
        chainModeActive = false
        ballSpeedMultiplier = 1
        removeAction(forKey: Self.chainKey)
        removeAction(forKey: Self.wideKey)
        removeAction(forKey: Self.slowKey)
        if paddle != nil { setPaddleWidth(config.paddleSize.width) }
    }

    private func clearTokensAndFields() {
        redFields.forEach { $0.removeFromParent() }
        redFields.removeAll()
        for child in children where child.physicsBody?.categoryBitMask == BBPhysicsCategory.powerUp {
            child.removeFromParent()
        }
    }

    // MARK: - Paddle english

    /// Reflect a ball off the paddle, steering the rebound by where it struck: centre
    /// goes near-vertical, the edges fan out to `maxBounceAngle` — rewarding skill shots.
    private func bounceOffPaddle(_ ball: SKShapeNode) {
        guard let paddle else { return }
        let half = paddleWidth / 2
        let offset = max(-1, min(1, (ball.position.x - paddle.position.x) / half))
        let angle = offset * config.maxBounceAngle               // from vertical
        let dir = CGVector(dx: sin(angle), dy: max(0.2, cos(angle)))
        setBallVelocity(ball, direction: dir)
    }
}

// MARK: - Contacts

extension BrickBreakerScene: SKPhysicsContactDelegate {
    func didBegin(_ contact: SKPhysicsContact) {
        let a = contact.bodyA
        let b = contact.bodyB
        let mask = a.categoryBitMask | b.categoryBitMask

        switch mask {
        case BBPhysicsCategory.ball | BBPhysicsCategory.brick:
            guard let ball = ballNode(in: a, b), let brick = node(in: a, b, category: BBPhysicsCategory.brick) as? SKShapeNode else { return }
            handleBallBrickContact(ball: ball, brickNode: brick)
        case BBPhysicsCategory.ball | BBPhysicsCategory.paddle:
            guard let ball = ballNode(in: a, b) else { return }
            bounceOffPaddle(ball)
        case BBPhysicsCategory.paddle | BBPhysicsCategory.powerUp:
            guard let token = node(in: a, b, category: BBPhysicsCategory.powerUp) else { return }
            collectPowerUp(token)
        default:
            break
        }
    }

    private func ballNode(in a: SKPhysicsBody, _ b: SKPhysicsBody) -> SKShapeNode? {
        node(in: a, b, category: BBPhysicsCategory.ball) as? SKShapeNode
    }

    private func node(in a: SKPhysicsBody, _ b: SKPhysicsBody, category: UInt32) -> SKNode? {
        if a.categoryBitMask == category { return a.node }
        if b.categoryBitMask == category { return b.node }
        return nil
    }
}

// MARK: - Helpers

private extension SKColor {
    /// Same hue, scaled brightness (used to darken a strong brick as it takes hits).
    func scaledBrightness(_ factor: CGFloat) -> SKColor {
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &bl, alpha: &a)
        let f = max(0, min(1, factor))
        return SKColor(red: r * f, green: g * f, blue: bl * f, alpha: a)
    }
}

private extension PowerUpKind {
    /// Compact encoding so the kind can ride along in a token's `userData`.
    var encoded: Int { PowerUpKind.allCases.firstIndex(of: self) ?? 0 }
    init?(encoded: Int) {
        let all = PowerUpKind.allCases
        guard encoded >= 0, encoded < all.count else { return nil }
        self = all[encoded]
    }
}
