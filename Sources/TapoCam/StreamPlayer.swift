import AVFoundation
import CStream
import Foundation
import QuartzCore

/// Pulls frames from one RTSP stream on a background thread and shows them
/// in an AVSampleBufferDisplayLayer. Reconnects by itself when the link drops.
final class StreamPlayer: ObservableObject {
    enum Status: Equatable {
        case connecting
        case playing
        case failed(String)
    }

    @Published private(set) var status: Status = .connecting
    let layer = AVSampleBufferDisplayLayer()

    private let url: String
    private let lockKey: String
    /// Set to 1 on stop so a connection still being opened gives up immediately.
    private let cancelFlag: UnsafeMutablePointer<Int32> = {
        let p = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()
    private let lock = NSLock()
    private var running = false
    private var current: OpaquePointer?
    private var thread: Thread?
    private var jitter = JitterBuffer()
    private var generation = 0 // bumps on reconnect so stale scheduled frames are dropped
    private let displayQueue = DispatchQueue(label: "tapocam.display", qos: .userInteractive)

    /// `lockKey` identifies the camera (its LAN address): logins to one camera are made one at a time.
    init(url: String, lockKey: String) {
        self.url = url
        self.lockKey = lockKey
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    deinit {
        stop()
        cancelFlag.deallocate()
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        cancelFlag.pointee = 0
        let t = Thread { [weak self] in self?.loop() }
        t.name = "rtsp"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        running = false
        cancelFlag.pointee = 1
        if let s = current { tc_abort(s) }
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { if self.status != s { self.status = s } }
    }

    /// Tapo refuses simultaneous logins to the same camera (both lenses at once),
    /// so connections to one host are made one at a time.
    private static var hostLocks: [String: NSLock] = [:]
    private static let hostLocksGuard = NSLock()

    private static func connectLock(for host: String) -> NSLock {
        hostLocksGuard.lock(); defer { hostLocksGuard.unlock() }
        if let l = hostLocks[host] { return l }
        let l = NSLock()
        hostLocks[host] = l
        return l
    }

    private func loop() {
        var err = [CChar](repeating: 0, count: 256)
        var retryDelay: TimeInterval = 1

        while isRunning {
            setStatus(.connecting)
            let hostLock = Self.connectLock(for: lockKey)
            hostLock.lock()
            let opened = isRunning ? tc_open(url, 10, cancelFlag, &err, Int32(err.count)) : nil
            hostLock.unlock()
            guard let s = opened else {
                setStatus(.failed(String(cString: err)))
                sleepWhileRunning(retryDelay)
                retryDelay = min(retryDelay * 2, 15)
                continue
            }

            lock.lock()
            current = s
            let stillRunning = running
            lock.unlock()
            if !stillRunning { tc_abort(s) }

            var gotFrame = false
            jitter.reset()
            generation += 1
            while isRunning {
                var pb: Unmanaged<CVPixelBuffer>?
                var pts = Double.nan
                let r = tc_read(s, &pb, &pts, &err, Int32(err.count))
                if r < 0 { break }
                guard r == 1, let buffer = pb?.takeRetainedValue() else { continue }
                if !gotFrame {
                    gotFrame = true
                    retryDelay = 1
                    setStatus(.playing)
                }
                schedule(buffer, pts: pts)
            }

            lock.lock()
            current = nil
            lock.unlock()
            tc_close(s)

            if isRunning {
                setStatus(.failed(String(cString: err)))
                sleepWhileRunning(retryDelay)
                retryDelay = min(retryDelay * 2, 15)
            }
        }
    }

    private func sleepWhileRunning(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
    }

    /// Holds the frame until its turn, so bursts from the network play smoothly.
    private func schedule(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        let now = CACurrentMediaTime()
        let wait = jitter.schedule(now: now) - now
        let gen = generation
        displayQueue.asyncAfter(deadline: .now() + max(0, wait)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.display(pixelBuffer)
        }
    }

    private func display(_ pixelBuffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format else { return }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}
