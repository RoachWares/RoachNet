import XCTest
@testable import RoachNetRuntime

/// How model loading reads the machine's memory. The Linux sources are parsed
/// by plain functions, so these run on every platform.
final class SystemMemoryTests: XCTestCase {
    func testMemAvailableIsReadFromProcMeminfo() {
        let meminfo = """
        MemTotal:       16303608 kB
        MemFree:         1203392 kB
        MemAvailable:    9845120 kB
        Buffers:          402124 kB
        """
        XCTAssertEqual(SystemMemory.memAvailable(meminfo: meminfo), 9_845_120 * 1024)
        XCTAssertNil(SystemMemory.memAvailable(meminfo: "MemTotal: 1 kB\n"))
        XCTAssertNil(SystemMemory.memAvailable(meminfo: "MemAvailable: lots kB\n"))
        XCTAssertNil(SystemMemory.memAvailable(meminfo: "MemAvailable: -4 kB\n"))
    }

    func testPressureStallInformationGivesALevel() {
        let calm = "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
        XCTAssertEqual(SystemMemory.pressureLevel(psi: calm), 1)
        XCTAssertEqual(SystemMemory.pressureLevel(psi: "some avg10=12.50 avg60=3.00 avg300=1.00 total=99\nfull avg10=2.00 avg60=0.00 avg300=0.00 total=9\n"), 2)
        XCTAssertEqual(SystemMemory.pressureLevel(psi: "some avg10=45.00 avg60=3.00 avg300=1.00 total=99\nfull avg10=2.00 avg60=0.00 avg300=0.00 total=9\n"), 4)
        XCTAssertEqual(SystemMemory.pressureLevel(psi: "some avg10=20.00 avg60=0 avg300=0 total=1\nfull avg10=11.00 avg60=0 avg300=0 total=1\n"), 4)
        // Some kernels and containers report no "full" line for memory.
        XCTAssertEqual(SystemMemory.pressureLevel(psi: "some avg10=0.10 avg60=0.00 avg300=0.00 total=5\n"), 1)
        XCTAssertNil(SystemMemory.pressureLevel(psi: ""))
        XCTAssertNil(SystemMemory.pressureLevel(psi: "some avg10=nan avg60=0 avg300=0 total=0\n"))
    }

    func testAvailableShareGivesALevelWhereThereIsNoPressureFile() {
        XCTAssertEqual(SystemMemory.pressureLevel(available: 8, total: 16), 1)
        XCTAssertEqual(SystemMemory.pressureLevel(available: 2, total: 16), 2)
        XCTAssertEqual(SystemMemory.pressureLevel(available: 0, total: 16), 4)
        XCTAssertEqual(SystemMemory.pressureLevel(available: 5, total: 0), 0)
    }

    func testTheRunningSystemReportsSomething() {
        XCTAssertGreaterThan(SystemMemory.total, 0)
        let available = SystemMemory.available()
        XCTAssertGreaterThan(available, 0)
        XCTAssertLessThanOrEqual(available, SystemMemory.total)
        XCTAssertTrue([0, 1, 2, 4].contains(SystemMemory.pressureLevel()))
    }
}
