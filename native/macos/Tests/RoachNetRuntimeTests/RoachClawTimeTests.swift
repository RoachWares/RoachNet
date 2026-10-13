import XCTest
@testable import RoachNetRuntime

/// RoachClaw's "user local time", written the way JavaScript's
/// `toLocaleString('en-US', { timeZone })` writes it.
final class RoachClawTimeTests: XCTestCase {
    private let afternoon = Date(timeIntervalSince1970: 1_791_900_000) // 2026-10-13 14:00:00 UTC

    func testLocalTimeUsesTheEnglishUSFormat() {
        XCTAssertEqual(NativeRuntime.localeDateTime(afternoon, timeZoneName: "UTC"), "10/13/2026, 2:00:00 PM")
        XCTAssertEqual(NativeRuntime.localeDateTime(afternoon, timeZoneName: "America/Indiana/Indianapolis"), "10/13/2026, 10:00:00 AM")
        XCTAssertEqual(NativeRuntime.localeDateTime(afternoon, timeZoneName: "Asia/Tokyo"), "10/13/2026, 11:00:00 PM")
        XCTAssertEqual(NativeRuntime.localeDateTime(afternoon.addingTimeInterval(-14 * 3_600), timeZoneName: "UTC"), "10/13/2026, 12:00:00 AM")
        XCTAssertEqual(NativeRuntime.localeDateTime(afternoon.addingTimeInterval(-2 * 3_600 + 5 * 60 + 9), timeZoneName: "UTC"), "10/13/2026, 12:05:09 PM")
    }

    /// Legacy zone names that ICU accepts but Ubuntu 24.04 leaves out of
    /// zoneinfo unless tzdata-legacy is installed. A DateFormatter traps on
    /// them there, which took the whole runtime down.
    func testLegacyZoneNamesAreFormattedInsteadOfCrashing() {
        XCTAssertEqual(NativeRuntime.localeDateTime(afternoon, timeZoneName: "US/Eastern"), "10/13/2026, 10:00:00 AM")
        XCTAssertEqual(NativeRuntime.localeDateTime(afternoon, timeZoneName: "America/Indianapolis"), "10/13/2026, 10:00:00 AM")
        // A name no one knows keeps the system's zone.
        XCTAssertFalse(NativeRuntime.localeDateTime(afternoon, timeZoneName: "Mars/Olympus_Mons").isEmpty)
    }
}
