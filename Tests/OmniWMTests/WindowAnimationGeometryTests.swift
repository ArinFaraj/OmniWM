// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class WindowAnimationGeometryTests: XCTestCase {
    func testPopInStartFrameIsScaledAndCenteredOnTile() {
        let tile = CGRect(x: 100, y: 200, width: 400, height: 300)
        let start = WindowAnimationGeometry.popInStartFrame(tile: tile, scale: 0.85)
        XCTAssertEqual(start.width, 340, accuracy: 0.0001)
        XCTAssertEqual(start.height, 255, accuracy: 0.0001)
        // Same center as the tile, so it grows outward from the middle.
        XCTAssertEqual(start.midX, tile.midX, accuracy: 0.0001)
        XCTAssertEqual(start.midY, tile.midY, accuracy: 0.0001)
        // Strictly smaller than the tile (a grow-in, not a shrink).
        XCTAssertLessThan(start.width, tile.width)
        XCTAssertLessThan(start.height, tile.height)
    }

    func testPopInIdentityAtScaleOne() {
        let tile = CGRect(x: 10, y: 20, width: 200, height: 100)
        XCTAssertEqual(WindowAnimationGeometry.popInStartFrame(tile: tile, scale: 1.0), tile)
    }

    func testPopOutShrinksTowardCenterAndLifts() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let out = WindowAnimationGeometry.popOutFrame(from: frame, scale: 0.82, lift: 10)
        XCTAssertEqual(out.width, 164, accuracy: 0.0001)
        XCTAssertEqual(out.height, 164, accuracy: 0.0001)
        // Horizontally centered, vertically lifted up by `lift`.
        XCTAssertEqual(out.midX, frame.midX, accuracy: 0.0001)
        XCTAssertEqual(out.midY, frame.midY - 10, accuracy: 0.0001)
    }

    func testInterpolateHitsExactEndpoints() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 50, y: 60, width: 40, height: 30)
        XCTAssertEqual(WindowAnimationGeometry.interpolate(a, b, 0), a)
        XCTAssertEqual(WindowAnimationGeometry.interpolate(a, b, 1), b)
    }

    func testInterpolateMidpoint() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 50, y: 50, width: 50, height: 50)
        XCTAssertEqual(
            WindowAnimationGeometry.interpolate(a, b, 0.5),
            CGRect(x: 25, y: 25, width: 75, height: 75)
        )
    }

    func testInterpolateClampsOutOfRangeProgress() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 50, y: 50, width: 50, height: 50)
        // Progress below 0 and above 1 must not overshoot the endpoints - this is what
        // keeps a dying window from flying past its pop-out target on a late tick.
        XCTAssertEqual(WindowAnimationGeometry.interpolate(a, b, -0.5), a)
        XCTAssertEqual(WindowAnimationGeometry.interpolate(a, b, 1.5), b)
    }
}
