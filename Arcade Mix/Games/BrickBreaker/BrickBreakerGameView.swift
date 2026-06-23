//
//  BrickBreakerGameView.swift
//  Arcade Mix
//
//  SwiftUI host for the Brick Breaker SpriteKit scene (portrait). Mirrors the AFL host:
//  a `SpriteView` under a SwiftUI HUD (back / score / lives / level) and a Game Over
//  panel, with the scene's state bridged through an ObservableObject model. Submits the
//  final score to the high-score backend, keyed by `GameID.brickBreaker`.
//

import SwiftUI
import SpriteKit
import Combine

struct BrickBreakerGameView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var backend: BackendProvider

    @StateObject private var model = BrickBreakerGameModel()

    // Keyboard control for Mac/Simulator testing (A/D or arrows; Space to launch).
    @FocusState private var keyboardFocused: Bool

    private var scoreText: String {
        String(format: String(localized: "Score_Label"), model.score)
    }

    var body: some View {
        ZStack {
            SpriteView(scene: model.scene)
                .ignoresSafeArea()
                .focusable()
                .focused($keyboardFocused)
                .onKeyPress(phases: .down) { press in handleKey(press) }

            hud

            if model.isGameOver {
                gameOverPanel
            }
        }
        .statusBarHidden()
        .defersSystemGestures(on: .bottom)
        .onAppear {
            model.start()
            keyboardFocused = true
        }
        .onChange(of: model.isGameOver) { _, isOver in
            guard isOver, model.score > 0, let user = backend.currentUser else { return }
            let finalScore = model.score
            Task { try? await backend.highScores.submit(score: finalScore, for: .brickBreaker, user: user) }
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let step: CGFloat = 40
        switch press.key {
        case .leftArrow:  model.scene.nudgePaddle(-step)
        case .rightArrow: model.scene.nudgePaddle(step)
        case .space:      model.scene.launchFromKeyboard()
        default:
            switch String(press.key.character).lowercased() {
            case "a": model.scene.nudgePaddle(-step)
            case "d": model.scene.nudgePaddle(step)
            default: return .ignored
            }
        }
        return .handled
    }

    // MARK: - HUD

    private var hud: some View {
        VStack {
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

                Text(String(format: String(localized: "BrickBreaker_Level_Label"), model.level))
                    .font(.subheadline.weight(.semibold))
                    .shrinkToFit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())

                HStack(spacing: 3) {
                    ForEach(0..<max(model.lives, 0), id: \.self) { _ in
                        Image(systemName: "circle.fill").font(.caption2)
                    }
                }
                .foregroundStyle(.pink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

                Text(scoreText)
                    .font(.headline.monospacedDigit())
                    .shrinkToFit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding()

            Spacer()
        }
        .foregroundStyle(.primary)
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
                    model.restart()
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

/// Bridges the SpriteKit scene's state into SwiftUI for the HUD.
@MainActor
final class BrickBreakerGameModel: ObservableObject {
    @Published var score = 0
    @Published var lives = 3
    @Published var level = 1
    @Published var isGameOver = false

    let scene: BrickBreakerScene

    init() {
        scene = BrickBreakerScene(size: CGSize(width: 320, height: 568))
        scene.scaleMode = .resizeFill
        scene.onScoreChanged = { [weak self] in self?.score = $0 }
        scene.onLivesChanged = { [weak self] in self?.lives = $0 }
        scene.onLevelChanged = { [weak self] in self?.level = $0 }
        scene.onGameOver = { [weak self] in self?.isGameOver = true }
    }

    func start() {
        scene.startGame()
    }

    func restart() {
        isGameOver = false
        score = 0
        scene.startGame()
    }
}
