import CTubeStick
import Foundation

func ts_result_string_swift(_ code: Int32) -> UnsafePointer<CChar> { ts_result_string(code) }

/// Where the app keeps its files: ~/Library/Application Support/TubeStick
public enum Storage {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TubeStick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    public static var channelListURL: URL { directory.appendingPathComponent("channels.json") }
    public static var firmwareURL: URL { directory.appendingPathComponent("xc5000.fw") }

    public static func loadChannelList() -> ChannelList? {
        guard let data = try? Data(contentsOf: channelListURL) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChannelList.self, from: data)
    }

    public static func save(_ list: ChannelList) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: channelListURL, options: .atomic)
    }
}
