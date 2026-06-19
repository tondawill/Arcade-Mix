//
//  RugbyGameView.swift
//  Arcade Mix
//
//  SwiftUI host for the Rugby SpriteKit scene. Mirrors `AFLGameView` (joystick scene,
//  score + back HUD, pass button, keyboard fallback, Game Over panel, high-score
//  submit) and adds a "Tackle N / 6" chip driven by the scene's tackle-set callback.
//

import SwiftUI
import SpriteKit
import Combine

struct RugbyGameView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var backend: BackendProvider

    @StateObject private var model = RugbyGameModel()

    private enum Phase { case modeSelect, playing }
    @State private var phase: Phase = .modeSelect

    @FocusState private var keyboardFocused: Bool
    @State private var upHeld = false
    @State private var downHeld = false
    @State private var leftHeld = false
    @State private var rightHeld = false

    private var scoreText: String {
        String(format: String(localized: "Score_Label"), model.score)
    }

    private var tackleText: String {
        String(format: String(localized: "Rugby_Tackle_Count"), model.tackleCount)
    }

    var body: some View {
        ZStack {
            switch phase {
            case .modeSelect:
                modeSelect
            case .playing:
                gameScreen
            }
        }
        .statusBarHidden()
        .onChange(of: model.isGameOver) { _, isOver in
            guard isOver, model.score > 0, let user = backend.currentUser else { return }
            let finalScore = model.score
            Task { try? await backend.highScores.submit(score: finalScore, for: .rugby, user: user) }
        }
    }

    // MARK: - Mode selection

    private var modeSelect: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "figure.rugby")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Game_Rugby_Title")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .shrinkToFit()
            }

            VStack(spacing: 12) {
                Button {
                    start(advanced: false)
                } label: {
                    modeLabel("Rugby_Mode_Normal", systemImage: "figure.run")
                }
                Button {
                    start(advanced: true)
                } label: {
                    modeLabel("Rugby_Mode_Advanced", systemImage: "hand.draw.fill")
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
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
            .padding()
        }
    }

    private func modeLabel(_ titleKey: LocalizedStringKey, systemImage: String) -> some View {
        HStack {
            Label(titleKey, systemImage: systemImage).bold().shrinkToFit()
            Spacer()
            Image(systemName: "chevron.right")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white)
    }

    private func start(advanced: Bool) {
        model.start(advanced: advanced)
        phase = .playing
        keyboardFocused = true
    }

    // MARK: - Game screen

    private var gameScreen: some View {
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
        .defersSystemGestures(on: .bottom)   // keep the bottom edge for passing/running, not a home-swipe
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
            if pressed { model.scene.nudgeSelection(by: ch == "e" ? 1 : -1) }
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
                        .shrinkToFit()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer()

                Text(tackleText)
                    .font(.headline.monospacedDigit())
                    .shrinkToFit()
                    .padding(.horizontal, 14)
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

            if !model.isGameOver {
                HStack {
                    Spacer()
                    if model.isPositioning {
                        Button {
                            model.scene.continueInteractiveRestart()
                        } label: {
                            Label("Rugby_Continue", systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.headline)
                                .shrinkToFit()
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    } else {
                        Button {
                            model.scene.passToAimedTeammate()
                        } label: {
                            Label("Rugby_Pass", systemImage: "hand.point.up.left.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.headline)
                                .shrinkToFit()
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
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

/// Bridges the Rugby scene's observable state (score, tackle count, game over) into SwiftUI.
@MainActor
final class RugbyGameModel: ObservableObject {
    @Published var score: Int = 0
    @Published var tackleCount: Int = 0
    @Published var isGameOver: Bool = false
    /// Advanced Mode: true while play is frozen for the player to drag their teammates.
    @Published var isPositioning: Bool = false

    let scene: RugbyGameScene

    init() {
        scene = RugbyGameScene(size: CGSize(width: 1334, height: 750))
        scene.scaleMode = .resizeFill
        scene.onScoreChanged = { [weak self] newScore in
            self?.score = newScore
        }
        scene.onTackleCountChanged = { [weak self] count in
            self?.tackleCount = count
        }
        scene.onPositioningChanged = { [weak self] positioning in
            self?.isPositioning = positioning
        }
        scene.onGameOver = { [weak self] in
            self?.isGameOver = true
        }
    }

    func start(advanced: Bool) {
        scene.advancedMode = advanced
        scene.startMatch()
    }

    func restart() {
        isGameOver = false
        score = 0
        tackleCount = 0
        isPositioning = false
        scene.startMatch()
    }
}
