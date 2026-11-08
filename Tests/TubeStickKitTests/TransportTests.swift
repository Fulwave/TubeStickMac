import CTubeStick
import XCTest
@testable import TubeStickKit

// Builders for synthetic MPEG-TS data, so the parser is tested without hardware or copyrighted captures.
private func crc32mpeg(_ d: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in d {
        crc ^= UInt32(b) << 24
        for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
    }
    return crc
}

private func withCRC(_ section: [UInt8]) -> [UInt8] {
    let crc = crc32mpeg(section)
    return section + [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
}

/// Splits a section into TS packets on `pid`.
private func packetize(pid: Int, section: [UInt8], cc: inout UInt8) -> [UInt8] {
    var out = [UInt8]()
    var body: [UInt8] = [0] + section          // pointer_field = 0
    var first = true
    while !body.isEmpty {
        var pkt = [UInt8](repeating: 0xFF, count: 188)
        pkt[0] = 0x47
        pkt[1] = UInt8((first ? 0x40 : 0) | (pid >> 8)); pkt[2] = UInt8(pid & 0xFF); pkt[3] = 0x10 | (cc & 15)
        cc = (cc + 1) & 15
        let n = min(184, body.count)
        pkt.replaceSubrange(4..<(4 + n), with: body[0..<n])
        body.removeFirst(n); first = false
        out += pkt
    }
    return out
}

private func utf16Name(_ s: String) -> [UInt8] {
    var u = Array(s.utf16.prefix(7)); while u.count < 7 { u.append(0) }
    return u.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
}

private func vctChannel(name: String, major: Int, minor: Int, program: Int) -> [UInt8] {
    var c = utf16Name(name)
    c += [UInt8(0xF0 | (major >> 6)), UInt8(((major & 0x3F) << 2) | (minor >> 8)), UInt8(minor & 0xFF)]
    c += [0x04, 0, 0, 0, 0]                       // modulation, carrier frequency
    c += [0x00, 0x01]                              // channel TSID
    c += [UInt8(program >> 8), UInt8(program & 0xFF)]
    c += [0x00, 0x02]                              // flags, service_type 2
    c += [0x00, 0x01]                              // source id
    c += [0xFC, 0x00]                              // descriptors_length 0
    return c
}

private func tvct(channels: [[UInt8]], section: Int = 0, last: Int = 0) -> [UInt8] {
    var body: [UInt8] = [0x00, 0x01, 0xC1, UInt8(section), UInt8(last), 0x00, UInt8(channels.count)]
    for c in channels { body += c }
    body += [0xFC, 0x00]                           // additional_descriptors_length 0
    let length = body.count + 4
    return withCRC([0xC8, UInt8(0xF0 | (length >> 8)), UInt8(length & 0xFF)] + body)
}

private func pat(tsid: Int, programs: [(Int, Int)]) -> [UInt8] {
    var body: [UInt8] = [UInt8(tsid >> 8), UInt8(tsid & 0xFF), 0xC1, 0, 0]
    for (prog, pid) in programs { body += [UInt8(prog >> 8), UInt8(prog & 0xFF), UInt8(0xE0 | (pid >> 8)), UInt8(pid & 0xFF)] }
    let length = body.count + 4
    return withCRC([0x00, UInt8(0xB0 | (length >> 8)), UInt8(length & 0xFF)] + body)
}

private func pmt(program: Int, pcr: Int, streams: [(Int, Int)]) -> [UInt8] {
    var body: [UInt8] = [UInt8(program >> 8), UInt8(program & 0xFF), 0xC1, 0, 0, UInt8(0xE0 | (pcr >> 8)), UInt8(pcr & 0xFF), 0xF0, 0x00]
    for (type, pid) in streams { body += [UInt8(type), UInt8(0xE0 | (pid >> 8)), UInt8(pid & 0xFF), 0xF0, 0x00] }
    let length = body.count + 4
    return withCRC([0x02, UInt8(0xB0 | (length >> 8)), UInt8(length & 0xFF)] + body)
}

private func es(pid: Int, cc: UInt8) -> [UInt8] {
    var pkt = [UInt8](repeating: 0xAA, count: 188)
    pkt[0] = 0x47; pkt[1] = UInt8(pid >> 8); pkt[2] = UInt8(pid & 0xFF); pkt[3] = 0x10 | (cc & 15)
    return pkt
}

private func services(_ a: OpaquePointer) -> [(Int, Int, String, Int)] {
    var raw = [ts_service](repeating: ts_service(), count: 64)
    let n = Int(ts_analyzer_services(a, &raw, 64))
    return raw.prefix(n).map { s in
        (Int(s.major), Int(s.minor), withUnsafeBytes(of: s.name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }, Int(s.program))
    }
}

final class TransportTests: XCTestCase {
    func testChannelTableIsParsedAndSorted() {
        var cc: UInt8 = 0
        let table = tvct(channels: [vctChannel(name: "TOONS", major: 33, minor: 2, program: 6),
                                    vctChannel(name: "MeTV", major: 33, minor: 1, program: 3)])
        let a = ts_analyzer_new()!; defer { ts_analyzer_free(a) }
        let data = packetize(pid: 0x1FFB, section: table, cc: &cc)
        data.withUnsafeBufferPointer { ts_analyzer_feed(a, $0.baseAddress, $0.count) }
        XCTAssertEqual(ts_analyzer_has_services(a), 1)
        let s = services(a)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].0, 33); XCTAssertEqual(s[0].1, 1); XCTAssertEqual(s[0].2, "MeTV"); XCTAssertEqual(s[0].3, 3)
        XCTAssertEqual(s[1].2, "TOONS")
    }

    func testTableSpanningSeveralPacketsAndSections() {
        var cc: UInt8 = 0
        let many = (1...8).map { vctChannel(name: "CH\($0)", major: 7, minor: $0, program: $0) }   // 8 x 32 bytes spans two packets
        let s0 = tvct(channels: Array(many[0..<4]), section: 0, last: 1)
        let s1 = tvct(channels: Array(many[4..<8]), section: 1, last: 1)
        let a = ts_analyzer_new()!; defer { ts_analyzer_free(a) }
        var data = packetize(pid: 0x1FFB, section: s0, cc: &cc)
        data.withUnsafeBufferPointer { ts_analyzer_feed(a, $0.baseAddress, $0.count) }
        XCTAssertEqual(ts_analyzer_has_services(a), 0, "table is incomplete until every section arrived")
        data = packetize(pid: 0x1FFB, section: s1, cc: &cc)
        data.withUnsafeBufferPointer { ts_analyzer_feed(a, $0.baseAddress, $0.count) }
        XCTAssertEqual(ts_analyzer_has_services(a), 1)
        XCTAssertEqual(services(a).count, 8)
    }

    func testCorruptSectionIsRejected() {
        var cc: UInt8 = 0
        var table = tvct(channels: [vctChannel(name: "BAD", major: 5, minor: 1, program: 1)])
        table[12] ^= 0xFF                                           // damage a byte so the CRC fails
        let a = ts_analyzer_new()!; defer { ts_analyzer_free(a) }
        let data = packetize(pid: 0x1FFB, section: table, cc: &cc)
        data.withUnsafeBufferPointer { ts_analyzer_feed(a, $0.baseAddress, $0.count) }
        XCTAssertEqual(ts_analyzer_has_services(a), 0)
    }

    func testLostPacketsAndResync() {
        var data = [UInt8]()
        data += [0x00, 0x11, 0x22]                                  // junk before the first sync byte
        for cc: UInt8 in [0, 1, 2, 5, 6] { data += es(pid: 0x100, cc: cc) }   // cc 3 and 4 are missing
        var damaged = es(pid: 0x100, cc: 7); damaged[1] |= 0x80      // transport_error_indicator
        data += damaged
        let a = ts_analyzer_new()!; defer { ts_analyzer_free(a) }
        data.withUnsafeBufferPointer { ts_analyzer_feed(a, $0.baseAddress, $0.count) }
        var q = ts_quality(); ts_analyzer_quality(a, &q)
        XCTAssertEqual(q.packets, 6)
        XCTAssertEqual(q.lost, 2)
        XCTAssertEqual(q.errorFlagged, 1)
        XCTAssertEqual(q.syncLosses, 3)
    }

    func testPacketsSplitAcrossFeedCalls() {
        var cc: UInt8 = 0
        let table = tvct(channels: [vctChannel(name: "SPLIT", major: 9, minor: 1, program: 1)])
        let data = packetize(pid: 0x1FFB, section: table, cc: &cc)
        let a = ts_analyzer_new()!; defer { ts_analyzer_free(a) }
        for chunk in stride(from: 0, to: data.count, by: 100) {
            let part = Array(data[chunk..<min(chunk + 100, data.count)])
            part.withUnsafeBufferPointer { ts_analyzer_feed(a, $0.baseAddress, $0.count) }
        }
        XCTAssertEqual(services(a).first?.2, "SPLIT")
    }

    func testProgramFilterKeepsOnlyOneProgram() {
        var patCC: UInt8 = 0, pmtCC: UInt8 = 0
        var input = [UInt8]()
        input += packetize(pid: 0, section: pat(tsid: 0x1234, programs: [(1, 0x30), (2, 0x40)]), cc: &patCC)
        input += packetize(pid: 0x30, section: pmt(program: 1, pcr: 0x31, streams: [(0x02, 0x31), (0x81, 0x32)]), cc: &pmtCC)
        input += packetize(pid: 0x40, section: pmt(program: 2, pcr: 0x41, streams: [(0x02, 0x41), (0x81, 0x42)]), cc: &pmtCC)
        for i in 0..<4 { for pid in [0x31, 0x32, 0x41, 0x42, 0x1FFB] { input += es(pid: pid, cc: UInt8(i)) } }

        final class Sink { var data = [UInt8]() }
        let sink = Sink()
        let filter = ts_program_filter_new(2, { p, n, ctx in
            Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue().data += UnsafeBufferPointer(start: p, count: n)
        }, Unmanaged.passUnretained(sink).toOpaque())!
        defer { ts_program_filter_free(filter) }
        // The first pass learns the tables, the second pass is what a running stream looks like.
        input.withUnsafeBufferPointer { ts_program_filter_feed(filter, $0.baseAddress, $0.count) }
        sink.data.removeAll()
        input.withUnsafeBufferPointer { ts_program_filter_feed(filter, $0.baseAddress, $0.count) }

        var pids = Set<Int>()
        for i in stride(from: 0, to: sink.data.count, by: 188) { pids.insert((Int(sink.data[i + 1] & 0x1F) << 8) | Int(sink.data[i + 2])) }
        XCTAssertEqual(pids, [0, 0x40, 0x41, 0x42])

        // The rewritten PAT must be valid and list only program 2.
        let a = ts_analyzer_new()!; defer { ts_analyzer_free(a) }
        sink.data.withUnsafeBufferPointer { ts_analyzer_feed(a, $0.baseAddress, $0.count) }
        XCTAssertEqual(ts_analyzer_transport_id(a), 0x1234)
        var q = ts_quality(); ts_analyzer_quality(a, &q)
        XCTAssertEqual(q.lost, 0)
    }

    /// Optional: set TUBESTICK_SAMPLE to a captured .ts file to check the parser against real broadcast data.
    func testRealCaptureIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["TUBESTICK_SAMPLE"], let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("TUBESTICK_SAMPLE not set")
        }
        let a = ts_analyzer_new()!; defer { ts_analyzer_free(a) }
        data.withUnsafeBytes { ts_analyzer_feed(a, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        XCTAssertEqual(ts_analyzer_has_services(a), 1)
        XCTAssertFalse(services(a).isEmpty)
    }
}
