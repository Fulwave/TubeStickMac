import CTubeStick
import Foundation
import TubeStickKit

let usage = """
tubestick: use the equinux TubeStick Hybrid ATSC (over-the-air digital TV) on macOS

  tubestick firmware               download the tuner firmware (once)
  tubestick scan [--all] [--channels 3,27,35]
                                   find stations; saves the list (RF channels 2-36, or 2-51 with --all)
  tubestick list                   show the saved station list
  tubestick watch <station>        tune, stream and open in VLC (Ctrl-C stops)
  tubestick record <station> <seconds> <file.ts>
  tubestick analyze <file.ts>      show the stations and quality in a captured stream (no stick needed)
  tubestick reset                  re-enumerate the stick (a software unplug and replug)

<station> is a number like 7.1, part of a name like "KABC", or rf27 for a whole RF channel.
"""

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func findStation(_ query: String) -> Result<Station, TubeStickError> {
    if query.lowercased().hasPrefix("rf"), let rf = Int(query.dropFirst(2)), (2...51).contains(rf) {
        return .success(Station(rfChannel: rf, major: rf, minor: 0, name: "RF \(rf)", program: 0, serviceType: 2, quality: .good))
    }
    guard let list = Storage.loadChannelList() else {
        return .failure(.message("No saved stations. Run \"tubestick scan\" first, or use rf27 for an RF channel."))
    }
    let q = query.lowercased()
    if let s = list.stations.first(where: { $0.number == query }) { return .success(s) }
    let byName = list.stations.filter { $0.name.lowercased().contains(q) }
    if byName.count == 1 { return .success(byName[0]) }
    if byName.count > 1 { return .failure(.message("\"\(query)\" matches: " + byName.map { $0.title }.joined(separator: ", "))) }
    return .failure(.message("No station \"\(query)\". Run \"tubestick list\"."))
}

func resolveStation(_ query: String) -> Station {
    switch findStation(query) {
    case .success(let s): return s
    case .failure(let e): fail(e.localizedDescription)
    }
}

func printStations(_ list: ChannelList) {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
    print("Scanned \(f.string(from: list.scannedAt))")
    for s in list.stations {
        print(String(format: "  %-6@ %-8@ RF %-3d %@%@", s.number as NSString, s.name as NSString, s.rfChannel, s.quality.rawValue,
                     s.isVideo ? "" : "  (audio/data)"))
    }
}

func sleepUntilInterrupted(while keepGoing: @escaping () -> Bool = { true }) {
    var stop = false
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { stop = true }
        s.resume()
        return s
    }
    while !stop && keepGoing() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }
    _ = sources
}

switch command {
case "firmware":
    if let url = Firmware.locate() { print("Firmware already installed: \(url.path)"); exit(0) }
    print("Downloading the XC5000 tuner firmware from kernel.org (linux-firmware project)...")
    do { print("Saved \(try Firmware.download().path)") } catch { fail("\(error.localizedDescription)") }

case "scan":
    var channels = Array(2...36)
    if args.contains("--all") { channels = Array(2...51) }
    if let i = args.firstIndex(of: "--channels"), i + 1 < args.count { channels = args[i + 1].split(separator: ",").compactMap { Int($0) } }
    let tuner = Tuner()
    do {
        try tuner.open()
        print("Scanning \(channels.count) RF channels (about 2 to 5 seconds each)...")
        let results = try tuner.scan(channels: channels, progress: { i, n, r in
            let found = r.stations.map { "\($0.number) \($0.name)" }.joined(separator: ", ")
            print(String(format: "  [%2d/%d] RF %-3d %@", i, n, r.rfChannel,
                         r.locked ? "\(r.quality.rawValue): \(found)" : "no signal"))
        })
        tuner.close()
        let stations = results.flatMap { $0.stations }.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
        let list = ChannelList(stations: stations)
        try Storage.save(list)
        print("")
        printStations(list)
    } catch { tuner.close(); fail("\(error.localizedDescription)") }

case "list":
    guard let list = Storage.loadChannelList() else { fail("No saved stations. Run \"tubestick scan\".") }
    printStations(list)

case "watch", "record":
    guard let query = args.first else { fail(usage) }
    let station = resolveStation(query)
    var recordURL: URL?
    if command == "record" {
        guard args.count >= 3, Double(args[1]) != nil else { fail("usage: tubestick record <station> <seconds> <file.ts>") }
        recordURL = URL(fileURLWithPath: args[2])
    } else if let i = args.firstIndex(of: "--record"), i + 1 < args.count { recordURL = URL(fileURLWithPath: args[i + 1]) }
    let player = Player()
    do {
        print("Tuning \(station.title) (RF \(station.rfChannel))...")
        try player.play(station, openInVLC: command == "watch" && !args.contains("--no-vlc"), recordTo: recordURL)
        print(command == "watch" ? "Playing. Press Ctrl-C to stop." : "Recording.")
        if command == "record", let seconds = Double(args[1]) { Thread.sleep(forTimeInterval: seconds) }
        else {
            print("Type another station (for example 7.1) and press Return to switch, or q to quit.")
            let lines = DispatchQueue(label: "stdin")
            var quit = false
            lines.async {
                while let line = readLine() {
                    let query = line.trimmingCharacters(in: .whitespaces)
                    if query == "q" { quit = true; return }
                    if query.isEmpty { continue }
                    DispatchQueue.main.async {
                        guard case .success(let next) = findStation(query) else {
                            if case .failure(let e) = findStation(query) { print(e.localizedDescription) }
                            return
                        }
                        do { print("Switching to \(next.title) (RF \(next.rfChannel))..."); try player.play(next); print("Playing \(next.title).") }
                        catch { print("Could not switch: \(error.localizedDescription)") }
                    }
                }
            }
            sleepUntilInterrupted(while: { !quit })
        }
    } catch { player.shutdown(); fail("\(error.localizedDescription)") }
    player.shutdown()
    print("Stopped.")

case "analyze":
    guard let path = args.first, let data = FileManager.default.contents(atPath: path) else { fail("usage: tubestick analyze <file.ts>") }
    let a = ts_analyzer_new()!
    data.withUnsafeBytes { ts_analyzer_feed(a, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
    var q = ts_quality(); ts_analyzer_quality(a, &q)
    print("packets \(q.packets), error-flagged \(q.errorFlagged), estimated lost \(q.lost), resync bytes \(q.syncLosses)")
    var services = [ts_service](repeating: ts_service(), count: 64)
    let n = Int(ts_analyzer_services(a, &services, 64))
    print(ts_analyzer_has_services(a) != 0 ? "Stations:" : "Stations (table incomplete):")
    for s in services.prefix(n) {
        let name = withUnsafeBytes(of: s.name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        print("  \(s.major).\(s.minor)  \(name)  program \(s.program)  type \(s.serviceType)")
    }
    ts_analyzer_free(a)

case "reset":
    var r: Int32 = 0
    guard let dev = ts_open(&r) else { fail(String(cString: ts_result_string(r))) }
    print(ts_reenumerate(dev) == 0 ? "Re-enumerating. Wait about 5 seconds before the next command." : "Reset failed.")

default:
    print(usage)
}
