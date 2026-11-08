import CTubeStick
import Foundation

/// Receives whole 188-byte transport stream packets on a background queue. Keep handlers fast.
public typealias PacketHandler = (UnsafePointer<UInt8>, Int) -> Void

private final class SinkBox {
    let lock = NSLock()
    var handler: PacketHandler?
    func deliver(_ p: UnsafePointer<UInt8>, _ n: Int) {
        lock.lock(); let h = handler; lock.unlock()
        h?(p, n)
    }
}

/// Owns the USB stick: opens it, loads firmware, tunes channels and streams the transport stream.
/// All methods block and may be called from any thread, but not concurrently; use one queue.
public final class Tuner {
    private var device: OpaquePointer?
    private let box = SinkBox()
    public private(set) var currentRFChannel: Int?

    public init() {}
    deinit { close() }

    public var isOpen: Bool { device != nil }
    public var isStreaming: Bool { device.map { ts_stream_running($0) != 0 } ?? false }

    /// Opens the stick and prepares the tuner (firmware is loaded only if the tuner does not already have it).
    public func open(firmware: Data? = Firmware.load()) throws {
        if device != nil { return }
        var result: Int32 = 0
        guard let dev = ts_open(&result) else { throw TubeStickError.device(result) }
        let rc: Int32 = firmware.map { fw in fw.withUnsafeBytes { ts_prepare(dev, $0.bindMemory(to: UInt8.self).baseAddress, fw.count) } }
            ?? ts_prepare(dev, nil, 0)
        if rc != 0 {
            ts_close(dev)
            throw rc == -4 ? TubeStickError.firmwareMissing : TubeStickError.device(rc)
        }
        device = dev
    }

    public func close() {
        guard let dev = device else { return }
        ts_close(dev)
        device = nil; currentRFChannel = nil
    }

    /// Tunes a US ATSC RF channel (2-51). Returns whether the demodulator locked. Safe while streaming.
    @discardableResult
    public func tune(rfChannel: Int, lockTimeout: TimeInterval = 2.0) throws -> Bool {
        guard let dev = device else { throw TubeStickError.message("The stick is not open.") }
        let rc = ts_tune(dev, Int32(rfChannel), Int32(lockTimeout * 1000))
        if rc < 0 { throw TubeStickError.device(rc) }
        currentRFChannel = rfChannel
        return rc == 1
    }

    public func setPacketHandler(_ handler: PacketHandler?) {
        box.lock.lock(); box.handler = handler; box.lock.unlock()
    }

    public func startStream() throws {
        guard let dev = device else { throw TubeStickError.message("The stick is not open.") }
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        let rc = ts_stream_start(dev, { packets, length, context in
            guard let packets = packets, let context = context else { return }
            Unmanaged<SinkBox>.fromOpaque(context).takeUnretainedValue().deliver(packets, length)
        }, ctx)
        if rc != 0 { throw TubeStickError.device(rc) }
    }

    public func stopStream() {
        if let dev = device { ts_stream_stop(dev) }
        setPacketHandler(nil)
    }

    public func signal() -> (locked: Bool, errorCount: UInt32)? {
        guard let dev = device else { return nil }
        var s = ts_signal()
        guard ts_read_signal(dev, &s) == 0 else { return nil }
        return (s.locked != 0, s.errorCount)
    }

    // MARK: - Scanning

    /// Tunes each RF channel in turn and reads the broadcast channel table for station names and numbers.
    /// The stream stays running while retuning. `progress` is called after each channel; return true from `shouldCancel` to stop.
    public func scan(channels: [Int] = Array(2...36),
                     progress: ((_ index: Int, _ total: Int, _ result: ChannelScanResult) -> Void)? = nil,
                     shouldCancel: () -> Bool = { false }) throws -> [ChannelScanResult] {
        guard device != nil else { throw TubeStickError.message("The stick is not open.") }
        guard let first = channels.first else { return [] }
        let analyzer = ts_analyzer_new()!
        defer { ts_analyzer_free(analyzer) }
        let analyzerLock = NSLock()

        _ = try tune(rfChannel: first, lockTimeout: 1.0)
        try startStream()
        defer { stopStream() }
        setPacketHandler { p, n in
            analyzerLock.lock(); ts_analyzer_feed(analyzer, p, n); analyzerLock.unlock()
        }

        var results: [ChannelScanResult] = []
        for (i, rf) in channels.enumerated() {
            if shouldCancel() { break }
            var result = ChannelScanResult(rfChannel: rf, locked: false, quality: .poor, stations: [], packets: 0, damagedPackets: 0)
            let locked = try tune(rfChannel: rf, lockTimeout: 1.5)
            if locked {
                analyzerLock.lock(); ts_analyzer_reset(analyzer); analyzerLock.unlock()
                // Station tables repeat several times a second; wait for a complete table and for enough packets to grade quality.
                let started = Date()
                var complete = false
                while Date().timeIntervalSince(started) < 8, !shouldCancel() {
                    Thread.sleep(forTimeInterval: 0.25)
                    analyzerLock.lock(); complete = ts_analyzer_has_services(analyzer) != 0; analyzerLock.unlock()
                    if complete && Date().timeIntervalSince(started) >= 1.5 { break }
                }
                analyzerLock.lock()
                var q = ts_quality(); ts_analyzer_quality(analyzer, &q)
                var raw = [ts_service](repeating: ts_service(), count: 64)
                let count = Int(ts_analyzer_services(analyzer, &raw, 64))
                analyzerLock.unlock()
                let damaged = q.errorFlagged + q.lost
                let grade = SignalQuality.grade(packets: q.packets, damaged: damaged)
                result.locked = true; result.quality = grade; result.packets = q.packets; result.damagedPackets = damaged
                result.stations = raw.prefix(min(count, 64)).map { s in
                    Station(rfChannel: rf, major: Int(s.major), minor: Int(s.minor), name: Tuner.string(s.name),
                            program: Int(s.program), serviceType: Int(s.serviceType), quality: grade)
                }.filter { !$0.name.isEmpty || $0.major != 0 }
            }
            results.append(result)
            progress?(i + 1, channels.count, result)
        }
        return results
    }

    private static func string(_ tuple: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                                         CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
