import CryptoKit
import Foundation

/// The XC5000 tuner needs a firmware file every time the stick is plugged in. The file is not part of this repository.
/// It is the public `dvb-fe-xc5000-1.6.114.fw` from the linux-firmware project (redistributable under Xceive's license),
/// or any other copy of that file you point TUBESTICK_FIRMWARE at.
public enum Firmware {
    public static let downloadURL = URL(string: "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/dvb-fe-xc5000-1.6.114.fw")!
    public static let knownSHA256 = "7104bda8df301fe1bd4c09de1708aeb6d0d8e1f9d55505449fecfad82639235f"

    /// Search order: TUBESTICK_FIRMWARE, then ~/Library/Application Support/TubeStick/xc5000.fw.
    public static func locate() -> URL? {
        if let path = ProcessInfo.processInfo.environment["TUBESTICK_FIRMWARE"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.fileExists(atPath: Storage.firmwareURL.path) ? Storage.firmwareURL : nil
    }

    public static func load() -> Data? { locate().flatMap { try? Data(contentsOf: $0) } }

    /// Downloads the public firmware file from kernel.org and checks it against the known SHA-256 before saving it.
    public static func download() throws -> URL {
        var result: Result<Data, Error> = .failure(TubeStickError.message("Download did not finish."))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: downloadURL) { data, response, error in
            if let data = data, (response as? HTTPURLResponse)?.statusCode == 200 { result = .success(data) }
            else { result = .failure(error ?? TubeStickError.message("The firmware server did not return the file.")) }
            done.signal()
        }.resume()
        done.wait()
        let data = try result.get()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == knownSHA256 else {
            throw TubeStickError.message("The downloaded firmware does not match the expected checksum (\(hash)); not saved.")
        }
        try data.write(to: Storage.firmwareURL, options: .atomic)
        return Storage.firmwareURL
    }
}
