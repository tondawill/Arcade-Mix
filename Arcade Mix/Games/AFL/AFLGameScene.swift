//
//  AFLGameScene.swift
//  Arcade Mix
//
//  AFL rules on top of `BaseGameScene`. The base default behavior already *is* AFL
//  (kick-off from behind, the Mark on a clean catch, crossing the forward-50 into a
//  set shot, forward handpasses, tackle = game over), so this subclass only supplies
//  the AFL `SportConfig` and the set-shot specifics that the base leaves open: the
//  four goal/behind posts and a leaping goalkeeper that can save a shot.
//

import SpriteKit
import UIKit

final class AFLGameScene: BaseGameScene {

    // Goalkeeper on the set shot: rests on the ground and LEAPS up to the ball's
    // height to catch it — shoot when he's down.
    private let keeperHalfWidth: CGFloat = 120   // inner post to inner post
    private let keeperHeight: CGFloat = 70
    private var keeperDownY: CGFloat { stagePostLineY - 160 }  // resting: the ball sails over
    private var keeperUpY: CGFloat { goalBallY }              // leaps up to catch it
    private weak var keeper: SKNode?

    init(size: CGSize) {
        super.init(size: size, config: .afl)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Set-shot staging

    /// Inner gap = goal, inner→outer = behind; plus a keeper that dwells on the ground
    /// to give a beatable window, then leaps to the ball's height.
    override func buildKickStage(on layer: SKNode) {
        super.buildKickStage(on: layer)   // the four posts

        let gk = SKSpriteNode(color: config.opponentColor,
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
    }

    /// Goal between the inner posts (unless the keeper catches it), behind outside them.
    override func resolveKick(landingX: CGFloat) {
        keeper?.removeAllActions()   // freeze so the result reads on a static frame
        let dx = abs(landingX - stageCenter.x)
        if dx <= 120 {
            if keeperSaves(landingX: landingX) {
                finishKick(points: 0, labelText: String(localized: "AFL_Saved"))
            } else {
                finishKick(points: 6, labelText: String(localized: "AFL_Goal"))
            }
        } else if dx <= 360 {
            finishKick(points: 1, labelText: String(localized: "AFL_Behind"))
        } else {
            finishKick(points: 0, labelText: nil)
        }
    }

    /// True if the keeper is actually overlapping the ball at the goal line on arrival.
    private func keeperSaves(landingX: CGFloat) -> Bool {
        guard let keeper else { return false }
        let dx = abs(landingX - keeper.position.x)
        let dy = abs(goalBallY - keeper.position.y)
        return dx <= keeperHalfWidth + config.ballRadius && dy <= keeperHeight / 2 + config.ballRadius
    }
}
