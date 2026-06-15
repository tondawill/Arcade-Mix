//
//  GameTileView.swift
//  Arcade Mix
//
//  A single selectable game tile in the hub grid. Reusable for every game; the
//  "Coming Soon" badge appears automatically based on `GameStatus`.
//

import SwiftUI

struct GameTileView: View {
    let game: GameInfo
    /// Top high score for this game, if any. Ignored for coming-soon games.
    var topScore: HighScore? = nil

    private var isComingSoon: Bool { game.status == .comingSoon }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: game.systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Text(game.titleKey)
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text(game.subtitleKey)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)

            if !isComingSoon {
                highScoreRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 180)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(game.accentColor.gradient)
        )
        .overlay(alignment: .topTrailing) {
            if isComingSoon {
                Text("Game_ComingSoon")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
            }
        }
        .opacity(isComingSoon ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var highScoreRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "trophy.fill")
            if let topScore {
                Text(verbatim: "\(topScore.score)").bold()
                Text(verbatim: "·")
                Text(verbatim: topScore.displayName).lineLimit(1)
            } else {
                Text("HighScore_None")
            }
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.95))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.18), in: Capsule())
    }
}
