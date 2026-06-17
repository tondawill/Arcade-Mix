//
//  AFLGameView.swift
//  Arcade Mix
//
//  SwiftUI host for the AFL SpriteKit scene. Uses SpriteKit's native `SpriteView`
//  (no UIViewController bridging needed). Overlays the HUD (score, back button)
//  and the Game Over panel in SwiftUI so they stay localized and easy to restyle.
//

import SwiftUI
import SpriteKit
import Combine

struct AFLGameView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var backend: BackendProvider

    // The scene is created once and observed for HUD state (score, game over).
    @StateObject private var model = AFLGameModel()

    // Keyboard movement for Mac/Simulator testing (arrow keys + WASD).
    @FocusState private var keyboardFocused: Bool
    @State private var upHeld = false
    @State private var downHeld = false
    @State private var leftHeld = false
    @State private var rightHeld = false

    /// "Score: %lld" resolved from the catalog with the current score injected.
    private var scoreText: String {
        String(format: String(localized: "Score_Label"), model.score)
    }

    var body: some View {
        ZStack {
            SpriteView(scene: model.scene)
                .ignoresSafeArea()
                .focusable()
                .focused($keyboardFocused)
                .onKeyPress(phases: [.down, .up]) { press in
                    handleKey(press)
                }

            hud

            if model.isGameOver {
                gameOverPanel
            }
        }
        .statusBarHidden()
        .onAppear {
            model.start()
            keyboardFocused = true
        }
        .onChange(of: model.isGameOver) { _, isOver in
            guard isOver, model.score > 0, let user = backend.currentUser else { return }
            let finalScore = model.score
            Task { try? await backend.highScores.submit(score: finalScore, for: .afl, user: user) }
        }
    }

    // MARK: - Keyboard movement

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let pressed = (press.phase == .down)
        let ch = String(press.key.character).lowercased()
        // Space passes to the highlighted teammate; Q/E cycle the target (once per key-down).
        if press.key == .space {
            if pressed { model.scene.passToAimedTeammate() }
            return .handled
        }
        if ch == "q" || ch == "e" {
            if pressed { model.scene.cyclePassTarget(by: ch == "e" ? 1 : -1) }
            return .handled
        }
        switch press.key {
        case .upArrow:
            upHeld = pressed
        case .downArrow:
            downHeld = pressed
        case .leftArrow:
            leftHeld = pressed
        case .rightArrow:
            rightHeld = pressed
        default:
            switch String(press.key.character).lowercased() {
            case "w": upHeld = pressed
            case "s": downHeld = pressed
            case "a": leftHeld = pressed
            case "d": rightHeld = pressed
            default: return .ignored
            }
        }
        pushKeyboardDirection()
        return .handled
    }

    private func pushKeyboardDirection() {
        // SpriteKit y is up, so up arrow → +y.
        let dx = CGFloat((rightHeld ? 1 : 0) - (leftHeld ? 1 : 0))
        let dy = CGFloat((upHeld ? 1 : 0) - (downHeld ? 1 : 0))
        let mag = hypot(dx, dy)
        let vector = mag == 0 ? CGVector.zero : CGVector(dx: dx / mag, dy: dy / mag)
        model.scene.setKeyboardDirection(vector)
    }

    // MARK: - HUD

    private var hud: some View {
        VStack {
            HStack {
                Button {
                    coordinator.returnToHub()
                } label: {
                    Label("Common_Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer()

                Text(scoreText)
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding()

            Spacer()

            if !model.isGameOver {
                HStack {
                    Spacer()
                    Button {
                        model.scene.passToAimedTeammate()
                    } label: {
                        Label("AFL_Handpass", systemImage: "hand.point.up.left.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding()
            }
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Game Over

    private var gameOverPanel: some View {
        VStack(spacing: 20) {
            Text("Game_Over")
                .font(.largeTitle.bold())

            Text(scoreText)
                .font(.title3.monospacedDigit())

            HStack(spacing: 16) {
                Button {
                    model.restart()
                } label: {
                    Text("Common_Retry").bold().frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    coordinator.returnToHub()
                } label: {
                    Text("Common_MainMenu").frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 20)
    }
}

/// Bridges the SpriteKit scene's observable state into SwiftUI for the HUD.
/// The scene reports score / game-over back through closures.
@MainActor
final class AFLGameModel: ObservableObject {
    @Published var score: Int = 0
    @Published var isGameOver: Bool = false

    let scene: AFLGameScene

    init() {
        scene = AFLGameScene(size: CGSize(width: 1334, height: 750))
        scene.scaleMode = .resizeFill
        scene.onScoreChanged = { [weak self] newScore in
            self?.score = newScore
        }
        scene.onGameOver = { [weak self] in
            self?.isGameOver = true
        }
    }

    func start() {
        scene.startMatch()
    }

    func restart() {
        isGameOver = false
        score = 0
        scene.startMatch()
    }
}
