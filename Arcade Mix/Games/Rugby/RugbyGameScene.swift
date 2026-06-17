//
//  RugbyGameScene.swift
//  Arcade Mix
//
//  Rugby League rules on top of `BaseGameScene`. Differences from AFL:
//    • the ball is kicked in from the try-line end (you collect it and run back at it),
//    • no Mark — catching on the full just gives clean possession; missing it lets the
//      ball roll further from the try line and to a random side, so you must chase it,
//    • passes go backwards only (forward teammates are greyed out and unselectable),
//    • crossing the try line scores a try (+4) and opens a pure-accuracy conversion (+2)
//      between two uprights (no keeper, no behind posts),
//    • a tackle no longer ends the game: you get a six-tackle set. Tackles 1–5 restart
//      play-the-ball at the spot with the defensive line retreating; being tackled on the
//      6th (a turnover) ends the game. Scoring a try resets the set.
//

import SpriteKit
import UIKit

final class RugbyGameScene: BaseGameScene {

    // MARK: - Tunables

    private let tackleSetSize = 6
    private let looseBallRollBack: ClosedRange<CGFloat> = 160...320   // distance the ball rolls away
    private let looseBallRollSide: ClosedRange<CGFloat> = -220...220  // sideways drift
    private let defenceRetreat: CGFloat = 250                          // play-the-ball line retreat (~10m)
    private let conversionHalfWidth: CGFloat = 120                     // inner-post to centre

    // MARK: - Set state

    private(set) var tackleCount = 0
    var onTackleCountChanged: ((Int) -> Void)?

    // MARK: - Init

    init(size: CGSize) {
        super.init(size: size, config: .rugby)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Start positions

    /// Receiver waits in their own half; support runners stay behind so they are valid
    /// backward-pass options from the first touch.
    override func placePlayersRandomly() {
        let w = config.fieldSize.width, h = config.fieldSize.height, m = config.margin
        let receiver = randomPoint(xIn: (w * 0.30)...(w * 0.45), yIn: m...(h - m))
        activePlayer?.position = receiver
        for mate in teammates {
            mate.position = randomPoint(xIn: m...max(m, receiver.x), yIn: m...(h - m))
        }
    }

    // MARK: - Kick-off

    /// Ball is kicked in from the try-line end back toward the receiver's half.
    override func configureKickoffFlight() {
        let w = config.fieldSize.width, h = config.fieldSize.height, m = config.margin
        flightStart = CGPoint(x: w - m, y: .random(in: m...(h - m)))
        flightEnd = CGPoint(x: .random(in: m...(w * 0.45)), y: .random(in: m...(h - m)))
    }

    /// No Mark: catching on the full just gives clean possession and starts the set.
    override func onAerialCaught(by node: SKNode) {
        gainPossession(by: node)
        enterPlayOn()
    }

    /// Missed gather: the ball rolls further from the try line and to a random side, then
    /// settles as a loose ball to chase (possession is still up for grabs).
    override func onAerialLanded(at point: CGPoint) {
        ball?.setScale(1.0)
        let m = config.margin, h = config.fieldSize.height
        let destX = max(m, point.x - .random(in: looseBallRollBack))
        let destY = min(max(point.y + .random(in: looseBallRollSide), m), h - m)
        ball?.removeAllActions()
        ball?.run(.move(to: CGPoint(x: destX, y: destY), duration: 0.5))
        enterPlayOn(resetBall: false)   // keep the roll animation alive
    }

    /// Every fresh possession (clean gather or chasing down a loose ball) starts a new set.
    override func gainPossession(by node: SKNode) {
        let wasUnowned = !hasPossession
        super.gainPossession(by: node)
        if wasUnowned, hasPossession { resetTackleSet() }
    }

    private func resetTackleSet() {
        tackleCount = 0
        onTackleCountChanged?(tackleCount)
    }

    // MARK: - Backward-only passing

    /// Only teammates level with or behind the carrier (smaller X, since play attacks +X).
    override func isEligiblePassTarget(_ mate: SKNode) -> Bool {
        guard let ap = activePlayer else { return false }
        return mate.position.x <= ap.position.x + 1
    }

    /// No forward-progress reward — backward outlets are judged purely on space.
    override func passProgressGain(mate: SKNode, carrier: CGPoint) -> CGFloat { 0 }

    /// Grey out (and dim) forward teammates each frame so the player can see who is a
    /// legal pass option.
    override func updateTeammateAppearance() {
        for mate in teammates {
            let eligible = isEligiblePassTarget(mate)
            (mate as? SKSpriteNode)?.color = eligible ? config.friendlyColor : Self.greyedColor
            mate.alpha = eligible ? 1.0 : 0.45
        }
    }

    private static let greyedColor = SKColor(white: 0.5, alpha: 1)

    /// Support runners trail behind the carrier so they stay legal backward options.
    override func teammateTargetX(carrierX: CGFloat) -> CGFloat {
        max(carrierX - config.teammateLeadAhead, config.margin)
    }

    // MARK: - Try + conversion

    override func didCrossScoringLine(at point: CGPoint) {
        addScore(4)
        showFloatingLabel(String(localized: "Rugby_Try"))
        resetTackleSet()
        // The conversion is taken in line with where the try was grounded: map the field
        // Y of the try to a lateral shift of the kick (wide tries must be angled back).
        let centerY = config.fieldSize.height / 2
        kickLateralOffset = max(-520, min(520, (point.y - centerY) * 0.85))
        beginKickPhase()
    }

    /// Two uprights and a crossbar, no keeper.
    override func buildKickStage(on layer: SKNode) {
        for dx in [-conversionHalfWidth, conversionHalfWidth] {
            let post = SKSpriteNode(color: .white, size: CGSize(width: 18, height: 360))
            post.position = CGPoint(x: stageCenter.x + dx, y: stagePostLineY)
            layer.addChild(post)
        }
        let bar = SKSpriteNode(color: .white, size: CGSize(width: conversionHalfWidth * 2 + 18, height: 14))
        bar.position = CGPoint(x: stageCenter.x, y: stagePostLineY - 60)
        layer.addChild(bar)
    }

    /// Between the posts → conversion (+2); otherwise a miss.
    override func resolveKick(landingX: CGFloat) {
        if abs(landingX - stageCenter.x) <= conversionHalfWidth {
            finishKick(points: 2, labelText: String(localized: "Rugby_Conversion"))
        } else {
            finishKick(points: 0, labelText: String(localized: "Rugby_Missed"))
        }
    }

    // MARK: - Six-tackle set

    override func didTackleCarrier(at point: CGPoint) {
        tackleCount += 1
        onTackleCountChanged?(tackleCount)

        if tackleCount >= tackleSetSize {
            // Tackled on the last play: turnover ends the game.
            showFloatingLabel(String(localized: "Rugby_Turnover"))
            triggerGameOver()
            return
        }

        // Stop play and show "Tackled"; the player lifts and re-presses to play the ball.
        pauseForRestart(label: String(localized: "AFL_Tackled")) { [weak self] in
            self?.playTheBall()
        }
    }

    /// Play-the-ball restart: keep possession at the tackle spot; the defensive line
    /// retreats goal-side (+X) to give a moment of space.
    private func playTheBall() {
        let maxX = config.fieldSize.width - config.playerSide / 2
        for opp in opponents {
            opp.position = CGPoint(x: min(opp.position.x + defenceRetreat, maxX), y: opp.position.y)
        }
    }
}
