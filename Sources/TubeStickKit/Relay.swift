import CTubeStick
import Darwin
import Foundation

/// Forwards transport stream packets to a UDP port on this Mac (for VLC) and optionally to a file,
/// optionally reduced to a single program.
public final class Relay {
    private var fd: Int32 = -1
    private var dest = sockaddr_in()
    private var pending = [UInt8]()
    private var file: FileHandle?
    private var filter: OpaquePointer?
    private let lock = NSLock()
    public private(set) var bytesOut: UInt64 = 0

    /// - Parameters:
    ///   - port: UDP port on 127.0.0.1, or nil for no network output.
    ///   - program: keep only this MPEG program (nil keeps everything).
    ///   - recordTo: also write the (filtered) stream to this file.
    public init(port: UInt16?, program: Int?, recordTo: URL? = nil) throws {
        if let port = port {
            fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw TubeStickError.message("Could not create a network socket.") }
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = port.bigEndian
            dest.sin_addr.s_addr = inet_addr("127.0.0.1")
        }
        if let url = recordTo {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            file = try FileHandle(forWritingTo: url)
        }
        pending.reserveCapacity(1316 * 4)
        if let program = program {
            filter = ts_program_filter_new(UInt16(program), { packets, length, context in
                guard let packets = packets, let context = context else { return }
                Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue().output(packets, length)
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    deinit { close() }

    public func feed(_ p: UnsafePointer<UInt8>, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        if let f = filter { ts_program_filter_feed(f, p, n) } else { output(p, n) }
    }

    private func output(_ p: UnsafePointer<UInt8>, _ n: Int) {
        bytesOut += UInt64(n)
        file?.write(Data(bytes: p, count: n))
        guard fd >= 0 else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        var offset = 0
        // 7 TS packets per datagram stays under the typical MTU.
        pending.withUnsafeBytes { raw in
            while pending.count - offset >= 1316 {
                var d = dest
                _ = withUnsafePointer(to: &d) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress! + offset, 1316, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                offset += 1316
            }
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let f = filter { ts_program_filter_free(f); filter = nil }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        try? file?.close(); file = nil
    }
}
