// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore
@preconcurrency import ScreenCaptureKit

/// Owned proxy surface for window pop-in / pop-out. A borderless, click-through,
/// all-Spaces NSPanel whose single CALayer holds a snapshot of a managed window. Because
/// OmniWM owns this window, CoreAnimation transforms on its layer are GPU-composited by
/// WindowServer and animate at refresh rate — the same "cached surface + transform"
/// technique Mission Control uses, with none of the foreign-window ownership limits.
///
/// Registered with SurfaceCoordinator capturePolicy `.excluded` so it never captures
/// itself recursively, matching DragGhostWindow.
@MainActor
final class WindowProxyPanel: NSPanel {
    let contentLayer = CALayer()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false

        let host = NSView()
        host.wantsLayer = true
        host.layer = CALayer()
        // Anchor at the center so a scale animation grows/shrinks about the middle,
        // keeping the proxy centered on the real window's frame.
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.contentsGravity = .resize
        contentLayer.isOpaque = false
        host.layer?.addSublayer(contentLayer)
        contentView = host

        SurfaceCoordinator.shared.register(
            window: self,
            id: "popin-\(ObjectIdentifier(self).hashValue)",
            policy: SurfacePolicy(
                kind: .dragGhost,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `appKitFrame` must already be in AppKit (bottom-left origin) screen coordinates.
    func install(image: CGImage, appKitFrame: CGRect) {
        setFrame(appKitFrame, display: false)
        contentLayer.bounds = CGRect(origin: .zero, size: appKitFrame.size)
        contentLayer.position = CGPoint(x: appKitFrame.width / 2, y: appKitFrame.height / 2)
        contentLayer.contents = image
    }
}

/// Plays a Hyprland-style pop-in (scale 0.85 -> 1.0 + fade) using an owned proxy surface.
/// Deliberately self-contained: it never touches the real (foreign) window. The caller
/// wires it into the window lifecycle and uses the callbacks to park/reveal the real
/// window, so the visual concern and the AX concern stay separate and testable.
///
/// `onComplete` is GUARANTEED to run exactly once (animation end OR a hard safety
/// timeout), so a caller that hides the real window on `onCaptured` can always rely on
/// `onComplete` to reveal it — a window can never get stranded hidden.
@MainActor
final class WindowPopInAnimator {
    static let shared = WindowPopInAnimator()

    private var panels: [Int: WindowProxyPanel] = [:]

    /// Hyprland windowsIn feel: near-critically-damped, ~popin. Curve approximates the
    /// easeOutQuint used by Hyprland's window-in channel.
    private static let popInCurve = CAMediaTimingFunction(controlPoints: 0.23, 1.0, 0.32, 1.0)

    /// - Parameters:
    ///   - onCaptured: called once the snapshot exists and the proxy is on-screen at the
    ///     target frame. The real window is safe to park/hide now. May be called with
    ///     `false` if capture failed (caller should then NOT park; just let the real
    ///     window appear normally).
    ///   - onComplete: called exactly once when the pop-in finishes or times out. The
    ///     caller reveals the real window here.
    func playPopIn(
        windowId: Int,
        topLeftFrame: CGRect,
        duration: TimeInterval = 0.28,
        onCaptured: @escaping (_ ok: Bool) -> Void,
        onComplete: @escaping () -> Void
    ) {
        var didComplete = false
        let complete: () -> Void = { [weak self] in
            guard !didComplete else { return }
            didComplete = true
            self?.teardown(windowId)
            onComplete()
        }
        // Hard safety net: whatever happens (capture hang, animation dropped, app quit),
        // the caller's reveal runs. This is the invariant that makes hiding-the-real-window safe.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.6) { complete() }

        Task { @MainActor in
            guard let image = await Self.capture(windowId: windowId, size: topLeftFrame.size) else {
                onCaptured(false)
                complete()
                return
            }
            let appKit = ScreenCoordinateSpace.toAppKit(rect: topLeftFrame)
            let panel = WindowProxyPanel()
            panel.install(image: image, appKitFrame: appKit)

            // Seed the start state without implicit animation, then order in.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.contentLayer.opacity = 0
            panel.contentLayer.transform = CATransform3DMakeScale(0.85, 0.85, 1)
            CATransaction.commit()

            panels[windowId] = panel
            panel.orderFront(nil)
            onCaptured(true)

            CATransaction.begin()
            CATransaction.setCompletionBlock { complete() }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.85
            scale.toValue = 1.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            for anim in [scale, fade] {
                anim.duration = duration
                anim.timingFunction = Self.popInCurve
            }
            // Model layer lands at the final state; the animations drive the visual.
            panel.contentLayer.transform = CATransform3DIdentity
            panel.contentLayer.opacity = 1
            panel.contentLayer.add(scale, forKey: "popin-scale")
            panel.contentLayer.add(fade, forKey: "popin-fade")
            CATransaction.commit()
        }
    }

    private func teardown(_ windowId: Int) {
        panels[windowId]?.orderOut(nil)
        panels[windowId] = nil
    }

    private static func capture(windowId: Int, size: CGSize) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(windowId) })
            else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(size.width))
            config.height = max(1, Int(size.height))
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }
}
