// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import os

/// A process-wide registry of the blocking (`.defaultTap`) CGEventTaps so they can be
/// force-disabled from *any* thread, without going through the main actor.
///
/// This is the escape hatch for the worst failure mode a window manager has: an active
/// session event tap whose callback is starved because the main thread is busy. macOS
/// then withholds input from every app until the tap times out. `SIGUSR1` (handled on a
/// background queue in `AppDelegate`) calls `disableAll()` here, which frees input
/// immediately while leaving the process alive - unlike `kill -9`, which also works but
/// loses the process and its state.
///
/// `CGEvent.tapEnable` operates on a Mach port and is safe to call off the main thread,
/// which is the whole point: the disable must run even when the main thread is wedged.
enum EmergencyTapControl {
    // CFMachPort isn't Sendable, but tapEnable on it is safe from any thread; box it so the
    // lock-guarded state and the cross-thread disable are allowed by the concurrency checker.
    private struct Box: @unchecked Sendable {
        let tap: CFMachPort
    }

    private struct State: Sendable {
        var taps: [Box] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func register(_ tap: CFMachPort) {
        let box = Box(tap: tap)
        state.withLock { $0.taps.append(box) }
    }

    static func unregister(_ tap: CFMachPort) {
        let box = Box(tap: tap)
        state.withLock { s in
            s.taps.removeAll { $0.tap === box.tap }
        }
    }

    /// Force every registered blocking tap off. Callable from any thread.
    static func disableAll() {
        let taps = state.withLock { $0.taps }
        for box in taps {
            CGEvent.tapEnable(tap: box.tap, enable: false)
        }
    }
}

/// Circuit breaker for the timeout re-enable path. macOS disables an unresponsive tap by
/// timeout; blindly re-enabling it means a workload that keeps stalling the main thread
/// (an app-launch storm, repeated full rescans) can loop freeze -> disable -> re-enable ->
/// freeze. After too many timeout-disables in a short window the breaker trips and the tap
/// is left disabled: management stops, but input keeps flowing - the safe failure mode.
final class TapReEnableBreaker: @unchecked Sendable {
    private struct State {
        var recentDisables: [TimeInterval] = []
        var tripped = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let windowSeconds: TimeInterval
    private let maxDisablesInWindow: Int
    private let label: String

    init(label: String, windowSeconds: TimeInterval = 5.0, maxDisablesInWindow: Int = 4) {
        self.label = label
        self.windowSeconds = windowSeconds
        self.maxDisablesInWindow = maxDisablesInWindow
    }

    /// Returns true if the caller should re-enable the tap, false if the breaker has tripped.
    func shouldReEnable(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { state in
            if state.tripped { return false }
            state.recentDisables.append(now)
            state.recentDisables.removeAll { now - $0 > windowSeconds }
            if state.recentDisables.count > maxDisablesInWindow {
                state.tripped = true
                Log.layout.fault(
                    "input tap '\(label)' tripped circuit breaker after \(state.recentDisables.count) timeout-disables in \(windowSeconds)s; leaving it disabled so input keeps flowing"
                )
                return false
            }
            return true
        }
    }
}
