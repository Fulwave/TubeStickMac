import AppKit
import Foundation

/// Plays a station: tunes it, streams it to a local UDP port and opens (or re-opens) that stream in VLC.
public final class Player {
    public let tuner: Tuner
    public let port: UInt16
    public private(set) var current: Station?
    private var relay: Relay?

    public var url: String { "udp://@127.0.0.1:\(port)" }

    public init(tuner: Tuner = Tuner(), port: UInt16 = 1234) {
        self.tuner = tuner; self.port = port
    }

    /// Switches to `station`. Retunes in place when the stick is already streaming, so switching takes about two seconds.
    public func play(_ station: Station, openInVLC: Bool = true, recordTo: URL? = nil) throws {
        try tuner.open()
        if tuner.currentRFChannel != station.rfChannel || !tuner.isStreaming {
            tuner.setPacketHandler(nil)
            guard try tuner.tune(rfChannel: station.rfChannel, lockTimeout: 3.0) else {
                if tuner.isStreaming { tuner.stopStream() }
                throw TubeStickError.noSignal(rfChannel: station.rfChannel)
            }
        }
        relay?.close()
        let newRelay = try Relay(port: port, program: station.program, recordTo: recordTo)
        relay = newRelay
        tuner.setPacketHandler { p, n in newRelay.feed(p, n) }
        if !tuner.isStreaming { try tuner.startStream() }
        current = station
        if openInVLC { try VLC.play(url: url) }
    }

    public func stop() {
        tuner.stopStream()
        relay?.close(); relay = nil
        current = nil
    }

    /// Stops streaming and releases the stick so other programs (or a replug) are safe.
    public func shutdown() {
        stop()
        tuner.close()
    }
}

public enum VLC {
    static let bundleID = "org.videolan.vlc"

    public static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    public static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// Opens the stream in VLC. When VLC is already running the URL is opened again, which makes it re-read the stream
    /// (needed after a channel change, because the new channel has different program tables).
    public static func play(url: String) throws {
        guard let app = appURL, let target = URL(string: url) else { throw TubeStickError.vlcNotFound }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: configuration, completionHandler: nil)
    }

    public static func quit() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }
}
