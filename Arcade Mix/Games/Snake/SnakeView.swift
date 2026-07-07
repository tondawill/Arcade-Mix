//
//  SnakeView.swift
//  Arcade Mix
//
//  Portrait SwiftUI host for Snake. Owns its own flow like Connect 4: a difficulty picker
//  (Easy / Medium / Hard, each showing the global best) opening straight from the hub, then
//  the game itself — a HUD (back / level / score) over a square-cell board drawn from
//  `SnakeViewModel`, a tap-to-continue level-complete card, and the game-over panel.
//  Steering is by swipe (primary) or the arrow keys / WASD on a hardware keyboard. The
//  final score is submitted keyed by `GameID.snake` and the difficulty the run started on.
//

import SwiftUI

struct SnakeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var backend: BackendProvider

    @StateObject private var vm = SnakeViewModel()

    // Keyboard steering for Mac/Simulator; touch users swipe the board.
    @FocusState private var keyboardFocused: Bool

    /// Difficulty-select vs. in-game. The game starts the moment a difficulty is picked.
    @State private var started = false
    /// Global best per difficulty, loaded for the select screen.
    @State private var bests: [SnakeDifficulty: HighScore] = [:]
    @State private var showHelp = false
    /// Hidden progression-testing mode, toggled by tapping the title 5×.
    @State private var debugEnabled = false

    // Dark backdrop; the board grid sits a touch lighter on top of it.
    private static let backdrop = Color(red: 0.05, green: 0.09, blue: 0.07)

    private var scoreText: String {
        String(format: String(localized: "Score_Label"), vm.score)
    }

    var body: some View {
        ZStack {
            Self.backdrop.ignoresSafeArea()

            if started {
                gameContent
            } else {
                difficultySelect
            }
        }
        .statusBarHidden()
        .onDisappear { vm.stop() }
    }

    // MARK: - Difficulty select

    private var difficultySelect: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Game_Snake_Title")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .shrinkToFit()
                    // Hidden: tap the title 5× to toggle progression-testing debug mode.
                    .onTapGesture(count: 5) { debugEnabled.toggle() }
                Text("Snake_ChooseDifficulty")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .shrinkToFit()
                if debugEnabled { debugBadge }
            }

            VStack(spacing: 12) {
                ForEach(SnakeDifficulty.allCases) { difficulty in
                    Button {
                        start(difficulty)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(difficulty.titleKey).bold().shrinkToFit()
                                bestCaption(for: difficulty)
                            }
                            Spacer()
                            Image(systemName: Self.icon(for: difficulty))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 520)
        .overlay(alignment: .topLeading) { circleButton("chevron.left") { coordinator.returnToHub() } }
        .overlay(alignment: .topTrailing) { circleButton("questionmark") { showHelp = true } }
        .sheet(isPresented: $showHelp) {
            if let info = GameInfo.catalog.first(where: { $0.id == .snake }) {
                HowToPlayView(info: info)
            }
        }
        .task { await loadBests() }
    }

    @ViewBuilder
    private func bestCaption(for difficulty: SnakeDifficulty) -> some View {
        if let best = bests[difficulty] {
            Text(String(format: String(localized: "Snake_GlobalBest"), best.score, best.displayName))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            Text("HighScore_None")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .shrinkToFit()
        }
    }

    private static func icon(for difficulty: SnakeDifficulty) -> String {
        switch difficulty {
        case .easy:   return "tortoise.fill"
        case .medium: return "hare.fill"
        case .hard:   return "flame.fill"
        }
    }

    private func circleButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(12)
                .background(.white.opacity(0.12), in: Circle())
        }
        .padding(20)
    }

    private func start(_ difficulty: SnakeDifficulty) {
        vm.beginGame(difficulty: difficulty, debug: debugEnabled)
        started = true
        keyboardFocused = true
    }

    private var debugBadge: some View {
        Text(verbatim: "DEBUG")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.yellow, in: Capsule())
    }

    private func loadBests() async {
        var result: [SnakeDifficulty: HighScore] = [:]
        for difficulty in SnakeDifficulty.allCases {
            if let best = try? await backend.highScores.topScore(for: .snake, difficulty: difficulty.rawValue) {
                result[difficulty] = best
            }
        }
        bests = result
    }

    // MARK: - Game

    private var gameContent: some View {
        ZStack {
            VStack(spacing: 16) {
                hud
                BoardView(vm: vm)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)

            if vm.isGameOver {
                gameOverPanel
            }

            if vm.isLevelComplete {
                levelCompletePanel
            }

            if vm.isPaused && !vm.isGameOver && !vm.isLevelComplete {
                PausedOverlay(
                    onResume: { vm.resume(); keyboardFocused = true },
                    onRestart: { vm.restart(); keyboardFocused = true },
                    onMainMenu: { coordinator.returnToHub() }
                )
            }
        }
        // Steer with a swipe anywhere on screen, not just over the board.
        .contentShape(Rectangle())
        .gesture(swipe)
        .focusable()
        .focused($keyboardFocused)
        .onKeyPress(phases: .down) { handleKey($0) }
        .onAppear { keyboardFocused = true }
        .onChange(of: vm.isGameOver) { _, isOver in
            // Debug runs never touch the leaderboard.
            guard isOver, !vm.isDebug, vm.score > 0, let user = backend.currentUser else { return }
            let finalScore = vm.score
            let difficulty = vm.startingDifficulty.rawValue
            Task { try? await backend.highScores.submit(score: finalScore, for: .snake, difficulty: difficulty, user: user) }
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

            Text(vm.levelLabel)
                .font(.subheadline.weight(.semibold))
                .shrinkToFit()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

            if vm.isDebug { debugBadge }

            Spacer()

            if !vm.isGameOver && !vm.isPaused && !vm.isLevelComplete {
                HUDPauseButton { vm.pause() }
            }

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

    // MARK: - Level Complete

    private var levelCompletePanel: some View {
        VStack(spacing: 20) {
            Text("Snake_LevelComplete")
                .font(.largeTitle.bold())
                .minimumScaleFactor(0.7)

            Text(scoreText)
                .font(.title3.monospacedDigit())
                .shrinkToFit()

            Text(String(format: String(localized: "Snake_NextLevel"), vm.nextLevelLabel))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .shrinkToFit()

            HStack(spacing: 16) {
                Button {
                    vm.advanceLevel()
                    keyboardFocused = true
                } label: {
                    Text("Common_Continue").bold().shrinkToFit().frame(minWidth: 120)
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

/// The portrait grid for the current level. Sizes square cells to the available width and
/// draws the walls (muted blocks), the pellet (a red circle), and the snake (rounded
/// segments, a brighter head).
private struct BoardView: View {
    @ObservedObject var vm: SnakeViewModel

    private static let boardColor = Color(red: 0.09, green: 0.16, blue: 0.12)
    private static let gridLine = Color.white.opacity(0.04)
    private static let bodyColor = Color(red: 0.30, green: 0.78, blue: 0.42)
    private static let headColor = Color(red: 0.56, green: 0.93, blue: 0.60)
    private static let foodColor = Color(red: 0.95, green: 0.32, blue: 0.32)
    private static let wallColor = Color(red: 0.34, green: 0.40, blue: 0.37)

    var body: some View {
        let cols = vm.columns
        let rows = vm.rows
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(cols)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Self.boardColor)

                grid(cell: cell, cols: cols, rows: rows)

                // Walls, beneath the snake and pellet.
                ForEach(Array(vm.walls.enumerated()), id: \.offset) { _, wall in
                    RoundedRectangle(cornerRadius: cell * 0.2, style: .continuous)
                        .fill(Self.wallColor)
                        .frame(width: cell - 2, height: cell - 2)
                        .offset(x: CGFloat(wall.x) * cell + 1,
                                y: CGFloat(wall.y) * cell + 1)
                }

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
