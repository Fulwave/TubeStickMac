import AppKit
import Combine
import TubeStickKit

/// Where the app shows itself. At least one of the two is always on, so the app can never be left with no way to reach it.
enum DisplayMode: String, CaseIterable, Identifiable {
    case both, dockOnly, menuBarOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "Dock and menu bar"
        case .dockOnly: return "Dock only"
        case .menuBarOnly: return "Menu bar only"
        }
    }
    var showsDock: Bool { self != .menuBarOnly }
    var showsMenuBar: Bool { self != .dockOnly }
}

/// State and actions shared by the window and the menu bar menu. All published state changes on the main thread;
/// all stick access happens on one serial background queue.
final class AppModel: ObservableObject {
    @Published var stations: [Station] = Storage.loadChannelList()?.stations ?? []
    @Published var status = "Ready"
    @Published var playing: Station?
    @Published var isScanning = false
    @Published var busy = false
    @Published var firmwareMissing = Firmware.locate() == nil
    @Published var displayMode: DisplayMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .both {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode") }
    }

    var onError: ((Error) -> Void)?
    private let player = Player()
    private let work = DispatchQueue(label: "com.fulwave.tubestick.work")
    private var cancelRequested = false

    var videoStations: [Station] { stations.filter { $0.isVideo } }

    private func onMain(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

    func play(_ station: Station) {
        guard !isScanning else { return }
        busy = true; status = "Tuning \(station.title)…"
        work.async {
            do {
                try self.player.play(station)
                self.onMain { self.playing = station; self.busy = false; self.status = "Playing \(station.title)" }
            } catch {
                self.onMain { self.playing = nil; self.busy = false; self.status = "Error: \(error.localizedDescription)"; self.onError?(error) }
            }
        }
    }

    func stop() {
        work.async {
            self.player.shutdown()   // also releases the stick so other tools can use it
            self.onMain { self.playing = nil; self.status = "Stopped" }
        }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true; busy = true; cancelRequested = false; status = "Scanning…"
        work.async {
            do {
                self.player.stop()
                self.onMain { self.playing = nil }
                try self.player.tuner.open()
                let results = try self.player.tuner.scan(progress: { i, n, r in
                    let note = r.stations.isEmpty ? "" : " — found \(r.stations.count) on RF \(r.rfChannel)"
                    self.onMain { self.status = "Scanning \(i) of \(n)\(note)" }
                }, shouldCancel: { self.cancelRequested })
                self.player.tuner.close()
                let canceled = self.cancelRequested
                if !canceled {
                    let found = results.flatMap { $0.stations }.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
                    try Storage.save(ChannelList(stations: found))
                    self.onMain { self.stations = found }
                }
                self.onMain {
                    self.isScanning = false; self.busy = false
                    self.status = canceled ? "Scan canceled" : "Found \(self.videoStations.count) stations"
                }
            } catch {
                self.player.tuner.close()
                self.onMain { self.isScanning = false; self.busy = false; self.status = "Error: \(error.localizedDescription)"; self.onError?(error) }
            }
        }
    }

    func cancelScan() { cancelRequested = true; status = "Canceling…" }

    func downloadFirmware() {
        status = "Downloading firmware…"
        work.async {
            do {
                _ = try Firmware.download()
                self.onMain { self.firmwareMissing = false; self.status = "Firmware installed. Ready." }
            } catch {
                self.onMain { self.status = "Error: \(error.localizedDescription)"; self.onError?(error) }
            }
        }
    }

    /// Stops the stream and releases the stick. A stream left running can hang the stick, so this runs on quit.
    func shutdown() {
        cancelRequested = true
        work.sync { player.shutdown() }
    }
}
