# OmniWM -> Hyprland parity: implementation plan (Path A, no-SIP)

Goal: a macOS WM that feels fully like Hyprland. NO partial-SIP / Dock injection, ever (user mandate). Full research + roadmap: /Users/arinfaraj/window-manager-research/report/hyprland-parity-roadmap.md

## Settled facts (empirically probed on macOS 26.5)
- Foreign-window SLS moves/transforms silently no-op (ownership model). AX is the honest real-move channel. Not a bug.
- `SLSSetWindowTransform` works at 120fps on OWNED windows. Added to SkyLight.swift (optional-resolved, `setWindowTransform(wid:_:)`).
- Off-screen/off-space capture returns LIVE pixels IFF the window keeps >=1px on some display (OmniWM parks at 1px = works). 0px overlap => hard error, not black. CONSTRAINT: never park a window fully off every display.
- The smooth path is the owned-proxy model: capture window -> own a proxy surface -> animate the proxy (CoreAnimation on an owned NSPanel layer, OR SLSSetWindowTransform) -> settle the real window once. This is what Apple's Mission Control does internally.

## Key gap discovered
Dwindle mode (what the user runs) has NO open or close animation at all - only window MOVES animate (CubicRectAnimation). The signature Hyprland window pop-in / pop-out is entirely absent. `startWindowCloseAnimation` is gated `layoutType != .dwindle` (AXEventHandler.swift:1242). This is the highest-value channel to add.

## Reusable infrastructure (already in the codebase)
- Capture: `DragGhostController.captureWindowThumbnail(windowId:targetSize:)` (SCScreenshotManager + SCContentFilter(desktopIndependentWindow:)).
- Owned proxy window: `DragGhostWindow` (borderless nonactivating NSPanel, transparent, click-through, `.canJoinAllSpaces`, registered with SurfaceCoordinator capturePolicy `.excluded` so it isn't captured recursively).
- Owned-window layer animation: standard CoreAnimation on the NSPanel's contentView.layer (scale + opacity) = GPU-smooth for our OWN window, no private API needed.
- Tick loop: `LayoutRefreshController.displayLinkFired` -> tickClosing/tickSlide (add tickProxy here) inside `SkyLight.shared.withTransactionScope`.
- Hooks: new-window admission = `AXEventHandler.trackPreparedCreate`; close = `prepareManagedWindowRemoval` (AXEventHandler.swift:1225).

## Channel build order (each: build isolated -> test -> wire in -> verify)
1. **Open pop-in (dwindle+niri)** — capturable (newborn exists), self-contained, biggest visible win.
   Sequence: capture newborn -> park real at 1px (hidden) -> proxy NSPanel with image at tile frame, layer scale 0.85->1.0 + alpha 0->1 (~250ms, Hyprland popin easeish) -> on completion reveal real at tile (AX) + remove proxy.
   SAFETY: a hard timeout MUST always reveal the real window even if capture/anim fails, so a window can never get stuck parked. Gate behind a `proxyOpenEnabled` flag, off until tested.
   Watch: newborn blank-first-frame (capture after 1 runloop tick); flash-before-park race (Probe #3).
2. **Close pop-out** — capture-timing race (window dying). Needs a snapshot from BEFORE destroy: keep a rolling last-snapshot per managed window (refresh on focus-out), animate that on close. Build after open.
3. **Overview polish** — already owns surfaces; if thumbnails go live, move CGContext -> CALayer.contents=IOSurface.
4. **Workspace slide (1:1 gesture)** — marquee. Real windows stay parked at 1px (capturable) during the slide; proxies (snapshots) animate; reveal real at end. Cleanest no-SIP channel (no double-image). Rebuild `workspaceSwitch` gesture like `columnScroll` (1:1). Flip `workspaceSlideEnabled` only when incoming renders via proxies. Gated on the transform calibration harness.

## Staged: open pop-in wiring (execute + VISUALLY VERIFY when screen is unlocked)
Built + compiled: `WindowPopInAnimator` (Core/Animation/WindowPopInAnimator.swift) - owned NSPanel proxy, CoreAnimation scale 0.85->1.0 + fade over ~0.28s, easeOutQuint-ish curve, capture via SCScreenshotManager, onComplete GUARANTEED once (safety timeout). Wired to nothing yet.
Wiring TODO (needs unlocked screen to verify):
1. Add flag `proxyPopInEnabled` (default false). Gate all of this behind it.
2. Hook: in the dwindle new-window path, when a token is brand-new AND its target tile T is known AND animations enabled AND flag on:
   - playPopIn(windowId, topLeftFrame: T, onCaptured: { ok in if ok { park the real window hidden at 1px } }, onComplete: { reveal the real window at T }).
   - Capture happens on the still-visible real window; then park; proxy grows at T; reveal at completion. Real window hidden only during the ~0.28s, and onComplete ALWAYS reveals (safety timeout) so it can never get stranded.
3. Verify visually: enable flag, rebuild, open several new windows (Finder, terminal, browser), watch for: correct position (coordinate Y-flip via ScreenCoordinateSpace.toAppKit), no double-image, no flash-before-park, smooth 120fps, clean reveal with no snap. Tune duration/curve/start-scale to taste.
4. KNOWN GOTCHAS from harness (SLS path; less relevant to the NSPanel CoreAnimation path but note): SLSSetWindowShape must precede drawing; content CGContext is Y-up while placement is Y-down; SkyLightWindowOrder.above==0 is actually kCGSOrderOut (LATENT BUG in SkyLight.swift:8 - should be 1; used by CommandPalette/WMController; fix WITH visual verification, not blind).
5. Then pop-out (close) via a rolling last-snapshot, overview polish, workspace slide.

## Tier-1 non-backend wins (independent, ship anytime)
- DONE: reduce-motion no-op fixed; SLSSetWindowTransform primitive added.
- TODO: input taps to a dedicated CFRunLoop thread (freeze-class structural fix; MouseEventHandler.swift:213 / Hotkeys.swift:497; lock-guarded SwallowSnapshot). Medium risk; do on a turn where input can be exercised + `pkill -USR1` ready.
- TODO: retire the dead foreign-SLS park path (AXManager.swift:1245) — removes per-move round-trip. Low risk but hot path.

## Hard rules
- Every proxy channel: real window is NEVER left hidden — a timeout reveal is mandatory.
- Never park a window with 0px on any display (capture fails hard).
- No SIP, no Dock injection, no foreign-window alpha. Ever.
- Build isolated, test, then wire behind a flag; verify via omniwmctl + logs (category "layout") + screenshots before enabling.
