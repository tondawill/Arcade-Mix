//
//  SnakeViewModel.swift
//  Arcade Mix
//
//  Pure-SwiftUI classic Snake. Foundation-only game logic driving an ObservableObject —
//  the View renders `snake`, `food`, and `score`, and feeds steering back in. The board
//  is a fixed portrait grid; the snake grows on eating, dies on a wall or itself, and the
//  tick speeds up gradually as it gets longer. Colours / SF Symbols live in the View,
//  mirroring the Connect 4 model/View split.
//

import Foundation
import Combine

@MainActor
final class SnakeViewModel: ObservableObject {

    /// A grid cell. Origin is top-left: x grows right, y grows down.
    struct Point: Equatable {
        let x: Int
        let y: Int
    }

    enum Direction {
        case up, down, left, right

        /// The step this direction adds to the head each tick.
        var delta: Point {
            switch self {
            case .up:    return Point(x: 0, y: -1)
            case .down:  return Point(x: 0, y: 1)
            case .left:  return Point(x: -1, y: 0)
            case .right: return Point(x: 1, y: 0)
            }
        }

        var opposite: Direction {
            switch self {
            case .up:    return .down
            case .down:  return .up
            case .left:  return .right
            case .right: return .left
            }
        }
    }

    /// The single pellet on the board. `bonus` pellets are smaller, worth more, and expire
    /// after `ttl` ticks (reverting to a regular pellet in place).
    struct Food {
        enum Kind {
            case regular
            case bonus

            var points: Int {
                switch self {
                case .regular: return 10
                case .bonus:   return 50
                }
            }
        }

        var cell: Point
        var kind: Kind
        var ttl: Int?
    }

    // MARK: - Grid

    /// Portrait board with square cells; taller than it is wide.
    static let columns = 15
    static let rows = 21

    // MARK: - Published state

    @Published private(set) var snake: [Point] = []   // head first
    @Published private(set) var direction: Direction = .up
    @Published private(set) var food = Food(cell: Point(x: 0, y: 0), kind: .regular, ttl: nil)
    @Published private(set) var score = 0
    @Published private(set) var isGameOver = false

    // MARK: - Tuning

    private let startLength = 3
    private let baseInterval = 0.34    // slow & relaxed at the start
    private let minInterval = 0.11     // fastest the snake ever moves
    private let decrement = 0.006      // shaved off per extra segment — a gentle ramp
    private let bonusChance = 0.15     // probability a fresh pellet is a bonus
    private let bonusTTL = 45          // ticks a bonus survives before reverting

    /// The next direction to apply — buffered so a mid-tick input can't reverse the snake
    /// into itself, and only one turn is honoured per tick.
    private var pendingDirection: Direction = .up
    private var loopTask: Task<Void, Never>?

    /// Current tick length: slower when short, easing toward `minInterval` as it grows.
    private var currentInterval: TimeInterval {
        max(minInterval, baseInterval - Double(snake.count - startLength) * decrement)
    }

    // MARK: - Lifecycle

    /// Reset to a fresh game and begin ticking. Safe to call again to restart.
    func start() {
        stop()
        reset()
        loopTask = Task { [weak self] in await self?.run() }
    }

    /// Cancel the tick loop (on disappear, game over, or before a restart).
    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func restart() {
        start()
    }

    deinit {
        loopTask?.cancel()
    }

    private func reset() {
        // Centre the snake, stacked vertically, heading up into open space.
        let midX = Self.columns / 2
        let midY = Self.rows / 2
        snake = (0..<startLength).map { Point(x: midX, y: midY + $0) }
        direction = .up
        pendingDirection = .up
        score = 0
        isGameOver = false
        spawnFood()
    }

    private func run() async {
        while !isGameOver {
            try? await Task.sleep(for: .seconds(currentInterval))
            if Task.isCancelled { return }
            step()
        }
    }

    // MARK: - Input

    /// Queue a turn for the next tick, ignoring a 180° reversal into the snake's neck.
    func setDirection(_ new: Direction) {
        guard !isGameOver else { return }
        if new == direction.opposite { return }
        pendingDirection = new
    }

    // MARK: - Simulation

    private func step() {
        direction = pendingDirection

        guard let head = snake.first else { return }
        let next = Point(x: head.x + direction.delta.x, y: head.y + direction.delta.y)

        // Wall collision.
        if next.x < 0 || next.x >= Self.columns || next.y < 0 || next.y >= Self.rows {
            gameOver()
            return
        }

        let ate = next == food.cell
        // Self collision. The tail cell frees up this tick unless we're growing, so it's
        // fair game when we're not eating.
        let body = ate ? snake : snake.dropLast()
        if body.contains(next) {
            gameOver()
            return
        }

        snake.insert(next, at: 0)
        if ate {
            score += food.kind.points
            spawnFood()
        } else {
            snake.removeLast()
            ageBonus()
        }
    }

    private func gameOver() {
        isGameOver = true
        stop()
    }

    /// Count a bonus pellet down; when it lapses, drop back to a plain pellet in place.
    private func ageBonus() {
        guard food.kind == .bonus, var ttl = food.ttl else { return }
        ttl -= 1
        if ttl <= 0 {
            food = Food(cell: food.cell, kind: .regular, ttl: nil)
        } else {
            food.ttl = ttl
        }
    }

    private func spawnFood() {
        let occupied = Set(snake.map { CellKey($0) })
        var free: [Point] = []
        for y in 0..<Self.rows {
            for x in 0..<Self.columns where !occupied.contains(CellKey(Point(x: x, y: y))) {
                free.append(Point(x: x, y: y))
            }
        }
        guard let cell = free.randomElement() else { return }   // board full = effectively a win

        if Double.random(in: 0..<1) < bonusChance {
            food = Food(cell: cell, kind: .bonus, ttl: bonusTTL)
        } else {
            food = Food(cell: cell, kind: .regular, ttl: nil)
        }
    }

    /// Hashable key for occupancy lookups (Point stays a plain Equatable value type).
    private struct CellKey: Hashable {
        let x, y: Int
        init(_ p: Point) { x = p.x; y = p.y }
    }
}
