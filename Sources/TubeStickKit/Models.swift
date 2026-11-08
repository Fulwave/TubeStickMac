import Foundation

/// One station (virtual channel) found on an RF channel, e.g. "7.1 WXYZ" on RF channel 27.
public struct Station: Codable, Hashable, Identifiable {
    public var rfChannel: Int
    public var major: Int
    public var minor: Int
    public var name: String
    /// MPEG program number inside the RF channel's transport stream.
    public var program: Int
    /// 2 = digital TV, 3 = audio only, 4 = data.
    public var serviceType: Int
    public var quality: SignalQuality

    public var id: String { "\(rfChannel)-\(program)-\(major).\(minor)" }
    public var number: String { "\(major).\(minor)" }
    public var title: String { name.isEmpty ? number : "\(number) \(name)" }
    public var isVideo: Bool { serviceType == 2 }

    public init(rfChannel: Int, major: Int, minor: Int, name: String, program: Int, serviceType: Int, quality: SignalQuality) {
        self.rfChannel = rfChannel; self.major = major; self.minor = minor; self.name = name
        self.program = program; self.serviceType = serviceType; self.quality = quality
    }
}

/// How clean the reception was while the channel was measured.
public enum SignalQuality: String, Codable, Comparable {
    case excellent, good, fair, poor

    /// Grades by the fraction of transport stream packets that were damaged or lost.
    public static func grade(packets: UInt64, damaged: UInt64) -> SignalQuality {
        guard packets > 0 else { return .poor }
        let fraction = Double(damaged) / Double(packets)
        if fraction < 0.001 { return .excellent }
        if fraction < 0.01 { return .good }
        if fraction < 0.05 { return .fair }
        return .poor
    }

    private var rank: Int { switch self { case .excellent: return 0; case .good: return 1; case .fair: return 2; case .poor: return 3 } }
    public static func < (a: SignalQuality, b: SignalQuality) -> Bool { a.rank < b.rank }
}

/// Result of measuring one RF channel during a scan.
public struct ChannelScanResult {
    public var rfChannel: Int
    public var locked: Bool
    public var quality: SignalQuality
    public var stations: [Station]
    public var packets: UInt64
    public var damagedPackets: UInt64
}

/// The saved result of a scan.
public struct ChannelList: Codable {
    public var scannedAt: Date
    public var stations: [Station]

    public init(scannedAt: Date = Date(), stations: [Station] = []) {
        self.scannedAt = scannedAt; self.stations = stations
    }
}

public enum TubeStickError: Error, LocalizedError {
    case device(Int32)
    case firmwareMissing
    case noSignal(rfChannel: Int)
    case vlcNotFound
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .device(let code): return String(cString: ts_result_string_swift(code))
        case .firmwareMissing: return "The tuner needs its firmware file. Run \"tubestick firmware\" to download it."
        case .noSignal(let rf): return "No signal on RF channel \(rf)."
        case .vlcNotFound: return "VLC is not installed. Get it from videolan.org."
        case .message(let m): return m
        }
    }
}
