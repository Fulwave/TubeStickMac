import XCTest
@testable import TubeStickKit

final class ModelTests: XCTestCase {
    func testQualityGrades() {
        XCTAssertEqual(SignalQuality.grade(packets: 100_000, damaged: 0), .excellent)
        XCTAssertEqual(SignalQuality.grade(packets: 100_000, damaged: 500), .good)
        XCTAssertEqual(SignalQuality.grade(packets: 100_000, damaged: 3_000), .fair)
        XCTAssertEqual(SignalQuality.grade(packets: 100_000, damaged: 20_000), .poor)
        XCTAssertEqual(SignalQuality.grade(packets: 0, damaged: 0), .poor)
        XCTAssertTrue(SignalQuality.excellent < SignalQuality.poor)
    }

    func testStationTitle() {
        let s = Station(rfChannel: 3, major: 33, minor: 1, name: "MeTV", program: 3, serviceType: 2, quality: .good)
        XCTAssertEqual(s.title, "33.1 MeTV")
        XCTAssertEqual(s.number, "33.1")
        XCTAssertTrue(s.isVideo)
    }

    func testChannelListRoundTrip() throws {
        let list = ChannelList(stations: [Station(rfChannel: 27, major: 7, minor: 2, name: "X", program: 2, serviceType: 2, quality: .fair)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(ChannelList.self, from: encoder.encode(list))
        XCTAssertEqual(back.stations, list.stations)
    }
}
