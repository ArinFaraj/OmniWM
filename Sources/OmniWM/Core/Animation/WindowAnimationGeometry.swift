// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

/// Pure frame math for the window pop-in / pop-out animations. Extracted so the geometry
/// is unit-testable independently of the AX/animation runtime (which needs a live display).
enum WindowAnimationGeometry {
    /// Start frame for a grow-in pop-in: a `scale`-sized rect centered on the target tile.
    /// The window animates from here to `tile`, so it grows outward from the tile's center.
    static func popInStartFrame(tile: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: tile.midX - tile.width * scale / 2.0,
            y: tile.midY - tile.height * scale / 2.0,
            width: tile.width * scale,
            height: tile.height * scale
        )
    }

    /// Target frame for a shrink-and-lift pop-out: a `scale`-sized rect centered on `frame`
    /// and lifted up by `lift` points. The dying window animates from `frame` to here.
    static func popOutFrame(from frame: CGRect, scale: CGFloat, lift: CGFloat) -> CGRect {
        CGRect(
            x: frame.midX - frame.width * scale / 2.0,
            y: frame.midY - frame.height * scale / 2.0 - lift,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    /// Linear interpolation between two frames, with progress clamped to [0, 1].
    static func interpolate(_ from: CGRect, _ to: CGRect, _ progress: CGFloat) -> CGRect {
        let t = min(max(progress, 0), 1)
        return CGRect(
            x: from.origin.x + (to.origin.x - from.origin.x) * t,
            y: from.origin.y + (to.origin.y - from.origin.y) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
    }
}
