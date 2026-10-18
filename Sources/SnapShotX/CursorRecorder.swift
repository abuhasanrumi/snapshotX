import AppKit
import CoreMedia

/// Notes where the pointer is, about 60 times a second, and every click, while a Studio Mode recording runs.
/// Times are on the host clock (the same clock the video frames use) until `track(start:)` makes them relative
/// to the first video frame.
@MainActor
final class CursorRecorder {
    private var region = CGRect.zero
    private var pixelsPerPoint = 2.0
    private var samples: [CursorTrack.Sample] = []
    private var clicks: [CursorTrack.Click] = []
    private var timer: Timer?
    private var monitors: [Any] = []

    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func start(region: CGRect, pixelsPerPoint: Double) {
        stop()
        self.region = region
        self.pixelsPerPoint = pixelsPerPoint
        samples = []
        clicks = []
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let time = Self.now()
            let button = event.type == .leftMouseDown ? 0 : (event.type == .rightMouseDown ? 1 : 2)
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.click(at: location, time: time, button: button) } }
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    private func sample() {
        let p = CursorTrack.normalize(NSEvent.mouseLocation, in: region)
        samples.append(.init(t: Self.now(), x: p.x, y: p.y))
    }

    private func click(at location: CGPoint, time: Double, button: Int) {
        let p = CursorTrack.normalize(location, in: region)
        clicks.append(.init(t: time, x: p.x, y: p.y, button: button))
    }

    /// The recorded track with times relative to `start`, the host-clock time of the first video frame.
    func track(start: CMTime) -> CursorTrack {
        stop()
        let offset = start.seconds
        var adjusted = samples
        // The last sample from before the video began becomes the position at time zero.
        if let index = adjusted.lastIndex(where: { $0.t < offset }) {
            adjusted[index].t = offset
        }
        return CursorTrack(pixelsPerPoint: pixelsPerPoint, samples: adjusted, clicks: clicks).rebased(by: offset)
    }
}
