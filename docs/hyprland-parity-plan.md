# OmniWM -> Hyprland parity: implementation plan (Path A, no-SIP)

Goal: a macOS WM that feels fully like Hyprland. NO partial-SIP / Dock injection, ever (user mandate). Full research + roadmap: /Users/arinfaraj/window-manager-research/report/hyprland-parity-roadmap.md

## Settled facts (empirically probed on macOS 26.5)
- Foreign-window SLS moves/transforms silently no-op (ownership model). AX is the honest real-move channel. Not a bug.
- `SLSSetWindowTransform` works at 120fps on OWNED windows. Added to SkyLight.swift (optional-resolved, `setWindowTransform(wid:_:)`).
- Off-screen/off-space capture returns LIVE pixels IFF the window keeps >=1px on some display (OmniWM parks at 1px = works). 0px overlap => hard error, not black. CONSTRAINT: never park a window fully off every display.
- **SCStream stays LIVE on parked windows (probed 2026-07-18)**: a continuous `SCStream` on a window parked at 1px delivers full-rate content updates - 29.1fps sustained (30fps cap), 100% `status=complete`, 30 distinct content states in 5s from a ticking clock. Probe source kept in the session scratchpad (`scprobe.swift`; CLI needs `-parse-as-library` + `NSApplication.shared` init before any CGS call).
  CONSEQUENCE: **live move/resize without SIP is viable** - park the real window (AX, legal), show its live-streaming texture on an owned proxy transformed at display rate, commit one real AX frame at gesture end. This was the "last 10-15%" previously believed to need Dock injection.
- Close events arrive POST-destroy (`prepareManagedWindowRemoval` runs off the destroyed notification), so a proxy close can never capture at close time. The texture must already exist -> the backend wants a **WindowTextureCache**: a low-rate SCStream (or opportunistic snapshot refresh on focus change / N-second tick) per visible managed window, retaining the last frame. Every proxy channel (close, open-latency hiding, drag) then reads from the cache instead of racing a capture.
- Multi-monitor validated (2026-07-18, 5120x1440 ultrawide + built-in): the per-display animation-slot model is contention-free across monitors - each display has its own slot and cross-monitor follow-moves keep both workspaces visible on their own monitors. All strand repros pass.
- The smooth path is the owned-proxy model: capture window -> own a proxy surface -> animate the proxy (CoreAnimation on an owned NSPanel layer, OR SLSSetWindowTransform) -> settle the real window once. This is what Apple's Mission Control does internally.

## Key gap discovered
~~Dwindle mode has NO open or close animation~~ RESOLVED 2026-07-18: dwindle now has frame-seeded pop-in (grow from 87%), close pop-out (AX shrink), and the incoming workspace slide - all strand-proofed (only the visible workspace animates; regression-tested). The user prefers the springy curve (0.35s, cp1 y=1.3 overshoot) over Hyprland's flat shipped defaults - do not "correct" it back.
Remaining gap: all of these animate the REAL window via AX writes, so smoothness is capped by each app's AX responsiveness, and close cannot fade (foreign window). The proxy channels below lift that cap.

## Reusable infrastructure (already in the codebase)
- Capture: `DragGhostController.captureWindowThumbnail(windowId:targetSize:)` (SCScreenshotManager + SCContentFilter(desktopIndependentWindow:)).
- Owned proxy window: `DragGhostWindow` (borderless nonactivating NSPanel, transparent, click-through, `.canJoinAllSpaces`, registered with SurfaceCoordinator capturePolicy `.excluded` so it isn't captured recursively).
- Owned-window layer animation: standard CoreAnimation on the NSPanel's contentView.layer (scale + opacity) = GPU-smooth for our OWN window, no private API needed.
- Tick loop: `LayoutRefreshController.displayLinkFired` -> tickClosing/tickSlide (add tickProxy here) inside `SkyLight.shared.withTransactionScope`.
- Hooks: new-window admission = `AXEventHandler.trackPreparedCreate`; close = `prepareManagedWindowRemoval` (AXEventHandler.swift:1225).

## Channel build order (each: build isolated -> test -> wire in -> verify)
0. **WindowTextureCache (foundation)** — BUILT + WIRED (timer-reconciled tracking in WMController). One SCStream per managed window at 10fps half-res, newest complete frame retained; per-window high-rate switch for gestures. Consumers convert to CGImage for CALayer contents (raw IOSurface does not reliably render). Layer-hosting panels must assign the layer BEFORE wantsLayer.
1. ~~Close pop-out via proxy~~ — BUILT, FIELD-TESTED, REJECTED (2026-07-19). The destroy notification lands after the app's own teardown is visible, so the ghost replays the close ~200ms late: the window visibly shrinks twice (the app/system close, then the proxy again). Without SIP nothing can suppress the dying window's own visuals or get the ghost up at t=0. Post-destroy close ghosts are structurally an echo. Code kept behind `proxyCloseEnabled = false` with the reasoning at the flag; the AX-shrink close remains the shipped behavior. Lesson for all channels: the proxy must OWN the timeline from before the visual change starts - never react to one that already happened.
2. **Open pop-in via proxy** — the timeline is ours (window admitted -> park -> proxy grows -> reveal), so the close-channel flaw does not apply. Capture newborn after 1 runloop tick -> park real at 1px -> proxy grows 87%->100% + fade in -> reveal real at tile. SAFETY: hard-timeout reveal is mandatory. `WindowPopInAnimator` is the skeleton.
3. **Overview polish** — already owns surfaces; if thumbnails go live, feed them from the cache (CALayer.contents=IOSurface).
4. **Workspace slide (1:1 gesture)** — marquee. INPUT PATH VERIFIED 2026-07-19: the scrollWheel CGEventTap already delivers continuous per-event deltas with full phase/momentumPhase lifecycle, and `TrackpadGestureIntent.resolveMode` receives cumulativeX/Y plus release velocity - the discrete switch (trigger at 140 units / flick >= 800) is purely a consumer choice. No new input plumbing needed.
   Build design (first real WindowTextureCache consumer - flip `textureCacheEnabled` on with this):
   - On workspaceSwitch resolve: identify current ws A and neighbor B, bump both workspaces' windows to high-rate streams, build one proxy panel per visible window from cached textures, park A's real windows at 1px. Gate: only go 1:1 when every visible window of A and B has a texture; otherwise degrade to today's seeded slide for that gesture.
   - Per delta: offset A-proxies by dx and B-proxies by dx offset one screen-width - owned panels, GPU-cheap. Rubber-band resistance when no neighbor exists.
   - On release: commit/cancel from displacement + velocity (existing isNextWorkspace + releaseFlickDisplacement logic), animate proxies to their final positions on the springy curve, switch the workspace model, place real windows, remove proxies.
   - Safety: a hard timeout ALWAYS reveals the active workspace's real windows.
5. **Live move/resize (the "impossible" one)** — on drag start: park real, show live-streamed proxy under the cursor at display rate; on release: one AX commit + reveal. Resize shows the live texture scaled (content reflows once at commit - same compromise Hyprland makes mid-gesture with its own scaling). Gate behind a flag; ship last.

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
