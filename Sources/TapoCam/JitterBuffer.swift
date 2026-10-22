import Foundation

/// Smooths out Wi-Fi bursts by showing frames at a steady pace.
///
/// Tapo timestamps are unreliable (repeats and jumps backwards), so the pace
/// comes from the measured arrival rate instead. Frames that arrive in a burst
/// get spread out; the small backlog this builds covers the next network gap.
/// When the backlog grows too much, playback runs slightly faster to stay live.
struct JitterBuffer {
    var targetBacklog = 0.3 // seconds of reserve before speeding up
    var maxBacklog = 1.0    // never lag more than this behind live

    private var interval = 1.0 / 15 // estimated time between frames
    private var lastArrival: Double?
    private var lastShow: Double?

    mutating func reset() {
        lastArrival = nil
        lastShow = nil
    }

    /// Returns the time (same clock as `now`) to show a frame arriving now.
    mutating func schedule(now: Double) -> Double {
        if let last = lastArrival {
            let gap = min(now - last, 1.0)
            interval += (gap - interval) * 0.02 // slow average: bursts and gaps cancel out
            interval = min(max(interval, 1.0 / 60), 0.5)
        }
        lastArrival = now

        guard let last = lastShow, now - last < 2 else {
            lastShow = now // first frame or after a long stall: show right away
            return now
        }

        var show = last + interval
        if show - now > targetBacklog { show -= interval * 0.15 } // catch up gently
        if show < now { show = now }
        if show - now > maxBacklog { show = now + targetBacklog } // too far behind
        lastShow = show
        return show
    }
}
