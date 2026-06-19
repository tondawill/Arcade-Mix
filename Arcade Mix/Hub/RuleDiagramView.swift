//
//  RuleDiagramView.swift
//  Arcade Mix
//
//  Simple SwiftUI-drawn illustrations used by the How to Play sheet to visualise a game's
//  key scoring rules — no image assets required. Add a `RuleDiagram` case + a drawing here
//  to give a new game's rule a picture.
//

import SwiftUI

/// Renders the drawing for a `RuleDiagram`. `accent` tints game-specific elements (e.g. the runner).
struct RuleDiagramView: View {
    let diagram: RuleDiagram
    var accent: Color = .accentColor

    var body: some View {
        switch diagram {
        case .pitch(let tryLine):   PitchDiagram(tryLine: tryLine, accent: accent)
        case .goalPosts(let rugby): GoalPostsDiagram(rugby: rugby)
        case .connectFour:          ConnectFourDiagram()
        }
    }
}

// MARK: - Field + scoring line, with a runner crossing it

private struct PitchDiagram: View {
    let tryLine: Bool
    let accent: Color

    static let grass = Color(red: 0.20, green: 0.5, blue: 0.24)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let lineX = w * (tryLine ? 0.80 : 0.66)
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Self.grass)
                RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.45), lineWidth: 2)

                // Scoring line (forward-50 / try line).
                Path { p in
                    p.move(to: CGPoint(x: lineX, y: 12)); p.addLine(to: CGPoint(x: lineX, y: h - 12))
                }.stroke(.white, lineWidth: 3)

                // Run direction toward the line.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.28, y: h / 2)); p.addLine(to: CGPoint(x: lineX + 10, y: h / 2))
                }.stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 5]))
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .position(x: lineX + 16, y: h / 2)

                // The carrier.
                Circle().fill(accent)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .position(x: w * 0.18, y: h / 2)
            }
        }
    }
}

// MARK: - Goal posts (AFL four posts / Rugby H + crossbar) with the ball scoring

private struct GoalPostsDiagram: View {
    let rugby: Bool

    static let ballColor = Color(red: 0.9, green: 0.55, blue: 0.15)
    // AFL post x-fractions and whether each is a tall (goal) post.
    private static let aflPosts: [(x: CGFloat, tall: Bool)] = [(0.30, false), (0.43, true), (0.57, true), (0.70, false)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(PitchDiagram.grass)
                if rugby { rugbyPosts(w: w, h: h) } else { aflPostsView(w: w, h: h) }
            }
        }
    }

    @ViewBuilder
    private func aflPostsView(w: CGFloat, h: CGFloat) -> some View {
        ForEach(0..<Self.aflPosts.count, id: \.self) { i in
            let post = Self.aflPosts[i]
            Capsule().fill(.white)
                .frame(width: 4, height: h * (post.tall ? 0.72 : 0.5))
                .position(x: w * post.x, y: h * 0.55)
        }
        ball.position(x: w * 0.5, y: h * 0.55)   // between the inner posts = goal
    }

    @ViewBuilder
    private func rugbyPosts(w: CGFloat, h: CGFloat) -> some View {
        let x1 = w * 0.40, x2 = w * 0.60
        let topY = h * 0.16, barY = h * 0.52, botY = h * 0.9
        Path { p in
            p.move(to: CGPoint(x: x1, y: topY)); p.addLine(to: CGPoint(x: x1, y: botY))
            p.move(to: CGPoint(x: x2, y: topY)); p.addLine(to: CGPoint(x: x2, y: botY))
            p.move(to: CGPoint(x: x1, y: barY)); p.addLine(to: CGPoint(x: x2, y: barY))
        }.stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        ball.position(x: (x1 + x2) / 2, y: h * 0.32)   // above the bar between posts
    }

    private var ball: some View {
        Circle().fill(Self.ballColor)
            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
            .frame(width: 16, height: 16)
    }
}

// MARK: - Connect 4 grid with a winning line of four lit

private struct ConnectFourDiagram: View {
    private let cols = 7
    private let rows = 6

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let cell = min((geo.size.width - 16 - spacing * CGFloat(cols - 1)) / CGFloat(cols),
                           (geo.size.height - 16 - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.13, green: 0.4, blue: 0.92))
                VStack(spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: spacing) {
                            ForEach(0..<cols, id: \.self) { c in
                                let win = (r == rows - 1) && (1...4).contains(c)   // bottom row, four in a row
                                Circle()
                                    .fill(win ? Color.red : Color(red: 0.06, green: 0.09, blue: 0.16))
                                    .frame(width: cell, height: cell)
                                    .overlay { if win { Circle().stroke(.white, lineWidth: 2) } }
                            }
                        }
                    }
                }
            }
        }
    }
}
