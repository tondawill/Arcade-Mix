//
//  Connect4View.swift
//  Arcade Mix
//
//  Bespoke portrait SwiftUI for Connect 4 — it shares nothing with the SpriteKit sports
//  games. Owns its own flow: a mode picker (vs Computer at four strengths, or pass-and-
//  play), the 7×6 board with tap-to-drop and a falling-disc animation, a turn / coin-flip
//  indicator, the highlighted winning line, and a result card (Rematch / Main Menu).
//

import SwiftUI

struct Connect4View: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var vm = Connect4ViewModel()

    // Classic palette: bright blue board, dark backdrop showing through the holes.
    private static let backdrop = Color(red: 0.06, green: 0.09, blue: 0.16)

    var body: some View {
        ZStack {
            Self.backdrop.ignoresSafeArea()

            switch vm.phase {
            case .modeSelect:
                modeSelect
            case .playing, .finished:
                gameScreen
            }
        }
        .statusBarHidden()
    }

    // MARK: - Mode selection

    private var modeSelect: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Game_Connect4_Title")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                recordCaption
            }

            VStack(spacing: 12) {
                Text("Connect4_VsComputer")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Difficulty.allCases) { difficulty in
                    Button {
                        vm.selectMode(.ai(difficulty))
                    } label: {
                        HStack {
                            Text(difficulty.titleKey).bold()
                            Spacer()
                            Image(systemName: difficulty.iconName)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.white)
                    }
                }
            }

            Button {
                vm.selectMode(.friend)
            } label: {
                Label("Connect4_VsFriend", systemImage: "person.2.fill")
                    .font(.headline)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
        }
        .padding(28)
        .frame(maxWidth: 520)
        .overlay(alignment: .topLeading) { backButton { coordinator.returnToHub() } }
    }

    @ViewBuilder
    private var recordCaption: some View {
        let record = ConnectFourStats.shared.combinedRecord()
        if record.total > 0 {
            Text(String(format: String(localized: "Connect4_Record"),
                        record.wins, record.losses, record.draws))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        } else {
            Text("Connect4_NoGames")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Game screen

    private var gameScreen: some View {
        VStack(spacing: 16) {
            HStack {
                backButton { vm.exitToModeSelect() }
                Spacer()
            }

            statusBar
                .padding(.horizontal, 24)

            BoardView(vm: vm)
                .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .overlay {
            if vm.phase == .finished {
                resultCard
            }
        }
    }

    private var statusBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(vm.currentPlayer.color)
                    .frame(width: 18, height: 18)
                    .opacity(vm.phase == .finished ? 0 : 1)
                Text(statusText)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }
            Text(coinFlipText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: LocalizedStringResource {
        if vm.isThinking { return "Connect4_Thinking" }
        switch vm.mode {
        case .ai:
            return vm.currentPlayer == vm.humanDisc ? "Connect4_Turn_You" : "Connect4_Turn_Computer"
        case .friend, .none:
            return vm.currentPlayer == .red ? "Connect4_Turn_Red" : "Connect4_Turn_Yellow"
        }
    }

    private var coinFlipText: LocalizedStringResource {
        vm.firstPlayer == .red ? "Connect4_CoinFlip_Red" : "Connect4_CoinFlip_Yellow"
    }

    // MARK: - Result

    private var resultCard: some View {
        VStack(spacing: 20) {
            Text(resultTitle)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button {
                    vm.rematch()
                } label: {
                    Text("Connect4_Rematch").bold().frame(minWidth: 120)
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
        .padding(24)
    }

    private var resultTitle: LocalizedStringResource {
        guard let winner = vm.winner else { return "Connect4_Draw" }
        switch vm.mode {
        case .ai:
            return winner == vm.humanDisc ? "Connect4_Win_You" : "Connect4_Win_Computer"
        case .friend, .none:
            return winner == .red ? "Connect4_Win_Red" : "Connect4_Win_Yellow"
        }
    }

    // MARK: - Shared bits

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding(14)
                .background(.white.opacity(0.12), in: Circle())
        }
        .padding(20)
    }
}

// MARK: - Board

/// The 7×6 grid. Sizes its cells to the available width and animates each disc dropping
/// in from the top of its column.
private struct BoardView: View {
    @ObservedObject var vm: Connect4ViewModel

    private let spacing: CGFloat = 8
    private static let boardColor = Color(red: 0.13, green: 0.4, blue: 0.92)
    private static let holeColor = Connect4View_backdrop

    var body: some View {
        let cols = ConnectFourBoard.columns
        let rows = ConnectFourBoard.rows
        GeometryReader { geo in
            let cell = (geo.size.width - spacing * CGFloat(cols + 1)) / CGFloat(cols)
            let unit = cell + spacing
            VStack(spacing: spacing) {
                ForEach((0..<rows).reversed(), id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<cols, id: \.self) { col in
                            cellView(col: col, row: row, size: cell, dropDistance: CGFloat(rows - row) * unit)
                        }
                    }
                }
            }
            .padding(spacing)
            .background(Self.boardColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .aspectRatio(CGFloat(cols) / CGFloat(rows), contentMode: .fit)
    }

    @ViewBuilder
    private func cellView(col: Int, row: Int, size: CGFloat, dropDistance: CGFloat) -> some View {
        let disc = vm.board.disc(column: col, row: row)
        let isWinning = vm.winningCells.contains(Cell(column: col, row: row))
        let dimmed = vm.phase == .finished && vm.winner != nil && !isWinning

        ZStack {
            Circle().fill(Self.holeColor)
            if let disc {
                Circle()
                    .fill(disc.color)
                    .overlay {
                        if isWinning {
                            Circle().stroke(.white, lineWidth: max(3, size * 0.10))
                        }
                    }
                    .opacity(dimmed ? 0.45 : 1)
                    .modifier(DropIn(distance: dropDistance))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { vm.dropColumn(col) }
    }
}

/// Animates a freshly placed disc falling from above its column into its slot.
private struct DropIn: ViewModifier {
    let distance: CGFloat
    @State private var dropped = false

    func body(content: Content) -> some View {
        content
            .offset(y: dropped ? 0 : -distance)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                    dropped = true
                }
            }
    }
}

// MARK: - UI mappings (kept out of the Foundation-only model/AI)

extension Disc {
    /// On-board colour for this piece.
    var color: Color {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        }
    }
}

extension Difficulty {
    var titleKey: LocalizedStringResource {
        switch self {
        case .easy: return "Connect4_Difficulty_Easy"
        case .medium: return "Connect4_Difficulty_Medium"
        case .hard: return "Connect4_Difficulty_Hard"
        case .impossible: return "Connect4_Difficulty_Impossible"
        }
    }

    var iconName: String {
        switch self {
        case .easy: return "tortoise.fill"
        case .medium: return "hare.fill"
        case .hard: return "flame.fill"
        case .impossible: return "bolt.fill"
        }
    }
}

/// The shared dark backdrop, exposed for the board's holes so they read as cut-outs.
private let Connect4View_backdrop = Color(red: 0.06, green: 0.09, blue: 0.16)
