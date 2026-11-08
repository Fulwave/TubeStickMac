import SwiftUI
import TubeStickKit

struct StationWindow: View {
    @ObservedObject var model: AppModel
    var onDisplayModeChange: (DisplayMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.status).font(.headline).lineLimit(2)
                Spacer()
                if model.isScanning {
                    Button("Cancel Scan") { model.cancelScan() }
                } else {
                    if model.playing != nil { Button("Stop") { model.stop() } }
                    Button("Scan for Stations") { model.scan() }.disabled(model.busy && model.playing == nil)
                }
            }

            if model.firmwareMissing {
                HStack {
                    Text("The stick's tuner needs a small firmware file (downloaded from kernel.org).")
                    Spacer()
                    Button("Download Firmware") { model.downloadFirmware() }
                }
                .padding(8).background(Color.yellow.opacity(0.2)).cornerRadius(6)
            }

            if model.videoStations.isEmpty {
                Spacer()
                Text("No stations yet. Click Scan for Stations (about 2 minutes).")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(model.videoStations) { station in
                    HStack {
                        Image(systemName: model.playing?.id == station.id ? "play.fill" : "tv")
                            .frame(width: 18).foregroundColor(model.playing?.id == station.id ? .accentColor : .secondary)
                        Text(station.number).monospacedDigit().frame(width: 52, alignment: .leading)
                        Text(station.name)
                        Spacer()
                        Text("RF \(station.rfChannel)").foregroundColor(.secondary).font(.caption)
                        Circle().fill(color(station.quality)).frame(width: 9, height: 9).help("Signal: \(station.quality.rawValue)")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.play(station) }
                    .contextMenu { Button("Watch in VLC") { model.play(station) } }
                }
            }

            HStack {
                Text("Double-click a station to watch it in VLC.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Picker("Show app in", selection: Binding(get: { model.displayMode }, set: { onDisplayModeChange($0) })) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).frame(width: 260)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 360)
    }

    private func color(_ q: SignalQuality) -> Color {
        switch q {
        case .excellent: return .green
        case .good: return Color(red: 0.55, green: 0.8, blue: 0.2)
        case .fair: return .orange
        case .poor: return .red
        }
    }
}
