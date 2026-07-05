//
//  SnakeView.swift
//  Arcade Mix
//
//  Portrait SwiftUI host for classic Snake. A HUD (back / score) sits over a square-cell
//  board drawn from `SnakeViewModel`. Steering is by swipe (primary) or the arrow keys on
//  a hardware keyboard (secondary). Submits the final score to the high-score backend,
//  keyed by `GameID.snake`, exactly like the other score games.
//

import SwiftUI

struct SnakeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var backend: BackendProvider

    @StateObject private var vm = SnakeViewModel()

    // Keyboard steering for Mac/Simulator; touch users swipe the board.
    @FocusState private var keyboardFocused: Bool

    // Dark backdrop; the board grid sits a touch lighter on top of it.
    private static let backdrop = Color(red: 0.05, green: 0.09, blue: 0.07)

    private var scoreText: String {
        String(format: String(localized: "Score_Label"), vm.score)
    }

    var body: some View {
        ZStack {
            Self.backdrop.ignoresSafeArea()

            VStack(spacing: 16) {
                hud
                BoardView(vm: vm)
                    .padding(.horizontal, 16)
                    .gesture(swipe)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)

            if vm.isGameOver {
                gameOverPanel
            }
        }
        .statusBarHidden()
        .focusable()
        .focused($keyboardFocused)
        .onKeyPress(phases: .down) { handleKey($0) }
        .onAppear {
            vm.start()
            keyboardFocused = true
        }
        .onDisappear { vm.stop() }
        .onChange(of: vm.isGameOver) { _, isOver in
            guard isOver, vm.score > 0, let user = backend.currentUser else { return }
            let finalScore = vm.score
            Task { try? await backend.highScores.submit(score: finalScore, for: .snake, user: user) }
        }
    }

    // MARK: - Input

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    vm.setDirection(dx > 0 ? .right : .left)
                } else {
                    vm.setDirection(dy > 0 ? .down : .up)
                }
            }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:    vm.setDirection(.up)
        case .downArrow:  vm.setDirection(.down)
        case .leftArrow:  vm.setDirection(.left)
        case .rightArrow: vm.setDirection(.right)
        default:
            switch String(press.key.character).lowercased() {
            case "w": vm.setDirection(.up)
            case "s": vm.setDirection(.down)
            case "a": vm.setDirection(.left)
            case "d": vm.setDirection(.right)
            default:  return .ignored
            }
        }
        return .handled
    }

    // MARK: - HUD

    private var hud: some View {
        HStack(spacing: 10) {
            Button {
                coordinator.returnToHub()
            } label: {
                Label("Common_Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .shrinkToFit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            Text(scoreText)
                .font(.headline.monospacedDigit())
                .shrinkToFit()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.primary)
        .padding(.horizontal)
    }

    // MARK: - Game Over

    private var gameOverPanel: some View {
        VStack(spacing: 20) {
            Text("Game_Over")
                .font(.largeTitle.bold())
                .minimumScaleFactor(0.7)

            Text(scoreText)
                .font(.title3.monospacedDigit())
                .shrinkToFit()

            HStack(spacing: 16) {
                Button {
                    vm.restart()
                    keyboardFocused = true
                } label: {
                    Text("Common_Retry").bold().shrinkToFit().frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    coordinator.returnToHub()
                } label: {
                    Text("Common_MainMenu").shrinkToFit().frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 20)
    }
}

// MARK: - Board

/// The fixed portrait grid. Sizes square cells to the available width and draws the snake
/// (rounded segments, a brighter head) and the pellet (regular = full circle, bonus =
/// smaller gold circle).
private struct BoardView: View {
    @ObservedObject var vm: SnakeViewModel

    private static let boardColor = Color(red: 0.09, green: 0.16, blue: 0.12)
    private static let gridLine = Color.white.opacity(0.04)
    private static let bodyColor = Color(red: 0.30, green: 0.78, blue: 0.42)
    private static let headColor = Color(red: 0.56, green: 0.93, blue: 0.60)
    private static let foodColor = Color(red: 0.95, green: 0.32, blue: 0.32)

    var body: some View {
        let cols = SnakeViewModel.columns
        let rows = SnakeViewModel.rows
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(cols)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Self.boardColor)

                grid(cell: cell, cols: cols, rows: rows)

                // Pellet.
                let food = vm.food
                let inset = cell * 0.12
                Circle()
                    .fill(Self.foodColor)
                    .frame(width: cell - inset * 2, height: cell - inset * 2)
                    .offset(x: CGFloat(food.x) * cell + inset,
                            y: CGFloat(food.y) * cell + inset)

                // Snake, head first.
                ForEach(Array(vm.snake.enumerated()), id: \.offset) { index, seg in
                    RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous)
                        .fill(index == 0 ? Self.headColor : Self.bodyColor)
                        .frame(width: cell - 2, height: cell - 2)
                        .offset(x: CGFloat(seg.x) * cell + 1,
                                y: CGFloat(seg.y) * cell + 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .aspectRatio(CGFloat(cols) / CGFloat(rows), contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func grid(cell: CGFloat, cols: Int, rows: Int) -> some View {
        Path { path in
            for c in 0...cols {
                let x = CGFloat(c) * cell
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: CGFloat(rows) * cell))
            }
            for r in 0...rows {
                let y = CGFloat(r) * cell
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: CGFloat(cols) * cell, y: y))
            }
        }
        .stroke(Self.gridLine, lineWidth: 1)
    }
}
