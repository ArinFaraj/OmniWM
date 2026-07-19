// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Keeps a continuously refreshed last-frame texture for managed windows, so proxy
/// animations always have pixels in hand. Close events arrive AFTER the window is
/// destroyed (`prepareManagedWindowRemoval` runs off the destroyed notification), so a
/// capture at close time is impossible - the texture must already exist. Probed
/// 2026-07-18: SCStream keeps delivering live full-rate frames even for windows parked
/// at 1px on a display, so streaming visible AND parked windows both work.
///
/// Built isolated; wired to nothing yet. Consumers: close pop-out proxy (first),
/// open pop-in, overview live thumbnails, workspace-slide proxies, live drag.
@MainActor
final class WindowTextureCache {
    struct CachedFrame {
        let pixelBuffer: CVPixelBuffer
        let capturedAt: CFTimeInterval

        var ioSurface: IOSurfaceRef? {
            CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        }

        /// CALayer.contents only reliably renders CGImage/NSImage, so consumers that put
        /// this texture on a layer convert once here (milliseconds, at animation start).
        func makeCGImage() -> CGImage? {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            return image
        }

        var age: CFTimeInterval {
            CACurrentMediaTime() - capturedAt
        }
    }

    /// Idle refresh rate. Cheap enough to run on every managed window; a gesture that
    /// needs display-rate frames should bump the stream it cares about via
    /// `setHighRate(windowId:enabled:)` rather than raising this default.
    private static let idleFrameInterval = CMTime(value: 1, timescale: 10)
    private static let highFrameInterval = CMTime(value: 1, timescale: 120)

    private final class StreamBox: @unchecked Sendable {
        let stream: SCStream
        let output: FrameSink
        init(stream: SCStream, output: FrameSink) {
            self.stream = stream
            self.output = output
        }
    }

    /// Receives frames on a background queue; the newest complete frame is kept under a
    /// lock so `latestFrame` is a cheap main-thread read.
    private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var newest: CachedFrame?

        var latest: CachedFrame? {
            lock.lock()
            defer { lock.unlock() }
            return newest
        }

        func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
            // Only complete frames carry new content; idle/blank frames would overwrite a
            // good texture with nothing.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                let status = attachments.first?[.status] as? Int,
                status != SCFrameStatus.complete.rawValue {
                return
            }
            let frame = CachedFrame(pixelBuffer: pixelBuffer, capturedAt: CACurrentMediaTime())
            lock.lock()
            newest = frame
            lock.unlock()
        }
    }

    private var streams: [CGWindowID: StreamBox] = [:]

    /// The most recent texture for a window, if it is being tracked and has delivered at
    /// least one complete frame. Valid even after the real window has been destroyed -
    /// that is the whole point.
    func latestFrame(for windowId: CGWindowID) -> CachedFrame? {
        streams[windowId]?.output.latest
    }

    var trackedWindowIds: Set<CGWindowID> {
        Set(streams.keys)
    }

    /// Begin streaming a window. Safe to call for an already-tracked id (no-op).
    /// Failures are silent by design: a missing texture only means the consumer falls
    /// back to a non-proxy animation, never a broken window.
    func startTracking(windowId: CGWindowID) {
        guard streams[windowId] == nil else { return }
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let window = content.windows.first(where: { $0.windowID == windowId })
            else { return }
            await self?.attachStream(to: window)
        }
    }

    func stopTracking(windowId: CGWindowID) {
        guard let box = streams.removeValue(forKey: windowId) else { return }
        Task { try? await box.stream.stopCapture() }
    }

    func stopAll() {
        let boxes = streams.values
        streams.removeAll()
        for box in boxes {
            Task { try? await box.stream.stopCapture() }
        }
    }

    /// Reconcile the tracked set against the currently managed windows. Called on a
    /// coarse timer: a window opened moments ago simply has no texture yet (consumers
    /// fall back), and a removed window's stream lingers at most one period. The cached
    /// frame for a dying window stays readable until this runs - the close animation
    /// reads it synchronously from the destroy event, well before the next sync.
    func syncTracking(managedIds: Set<CGWindowID>) {
        for id in managedIds where streams[id] == nil {
            startTracking(windowId: id)
        }
        for id in trackedWindowIds where !managedIds.contains(id) {
            stopTracking(windowId: id)
        }
    }

    /// Bump one window's stream to display rate for the duration of a gesture.
    func setHighRate(windowId: CGWindowID, enabled: Bool) {
        guard let box = streams[windowId] else { return }
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = enabled ? Self.highFrameInterval : Self.idleFrameInterval
        config.queueDepth = 3
        config.showsCursor = false
        Task { try? await box.stream.updateConfiguration(config) }
    }

    private func attachStream(to window: SCWindow) async {
        let windowId = window.windowID
        guard streams[windowId] == nil else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Half resolution: these textures only ever back brief proxy animations
        // (shrink-and-fade close, slide), where full res is imperceptible and doubles
        // the memory of every idle stream.
        config.width = max(64, Int(window.frame.width) / 2)
        config.height = max(64, Int(window.frame.height) / 2)
        config.scalesToFit = true
        config.minimumFrameInterval = Self.idleFrameInterval
        config.queueDepth = 3
        config.showsCursor = false
        let sink = FrameSink()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "omniwm.texturecache"))
            try await stream.startCapture()
        } catch {
            Log.layout.debug("WindowTextureCache: stream start failed for window \(windowId): \(error)")
            return
        }
        streams[windowId] = StreamBox(stream: stream, output: sink)
    }
}
