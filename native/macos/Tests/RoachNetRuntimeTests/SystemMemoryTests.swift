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

    func testCgroupFoldersAreReadFromTheProcessMembership() {
        let unified = SystemMemory.cgroupDirectories(procSelfCgroup: "0::/user.slice/user-1000.slice/session-2.scope\n")
        XCTAssertEqual(unified.version, 2)
        XCTAssertEqual(unified.directories, [
            "/sys/fs/cgroup/user.slice/user-1000.slice/session-2.scope",
            "/sys/fs/cgroup/user.slice/user-1000.slice",
            "/sys/fs/cgroup/user.slice",
            "/sys/fs/cgroup",
        ])
        // A container sees its own cgroup as the root.
        XCTAssertEqual(SystemMemory.cgroupDirectories(procSelfCgroup: "0::/\n").directories, ["/sys/fs/cgroup"])
        // Hybrid: the v1 memory controller is the one that sets limits.
        let hybrid = SystemMemory.cgroupDirectories(procSelfCgroup: "9:name=systemd:/\n4:memory:/jobs/shell\n2:cpuacct:/jobs\n0::/\n")
        XCTAssertEqual(hybrid.version, 1)
        XCTAssertEqual(hybrid.directories, ["/sys/fs/cgroup/memory/jobs/shell", "/sys/fs/cgroup/memory/jobs", "/sys/fs/cgroup/memory"])
        XCTAssertEqual(SystemMemory.cgroupDirectories(procSelfCgroup: "5:cpu,memory:/a\n").directories, ["/sys/fs/cgroup/memory/a", "/sys/fs/cgroup/memory"])
        XCTAssertEqual(SystemMemory.cgroupDirectories(procSelfCgroup: "").directories, [])
    }

    /// The folders come from where each hierarchy is mounted, as
    /// /proc/self/mountinfo says, not from a fixed path.
    func testCgroupFoldersFollowTheMounts() {
        // cgroup v1 with the memory controller sharing a mount with cpu.
        let shared = "30 25 0:26 / /sys/fs/cgroup/cpu,memory rw,nosuid shared:9 - cgroup cgroup rw,cpu,memory\n"
        XCTAssertEqual(SystemMemory.cgroupDirectories(procSelfCgroup: "5:cpu,memory:/a/b\n", mountinfo: shared).directories,
                       ["/sys/fs/cgroup/cpu,memory/a/b", "/sys/fs/cgroup/cpu,memory/a", "/sys/fs/cgroup/cpu,memory"])
        // A container on cgroup v1: its own cgroup is the mount's root, so the
        // mount's folder is the container's cgroup and nothing above shows.
        let container = "41 37 0:33 /docker/abc /sys/fs/cgroup/memory ro,nosuid master:15 - cgroup cgroup rw,memory\n"
        XCTAssertEqual(SystemMemory.cgroupDirectories(procSelfCgroup: "4:memory:/docker/abc\n", mountinfo: container).directories,
                       ["/sys/fs/cgroup/memory"])
        XCTAssertEqual(SystemMemory.cgroupDirectories(procSelfCgroup: "4:memory:/docker/abc/job\n", mountinfo: container).directories,
                       ["/sys/fs/cgroup/memory/job", "/sys/fs/cgroup/memory"])
        // A cgroup the mount doesn't show: only the mount's folder is read.
        XCTAssertEqual(SystemMemory.cgroupDirectories(procSelfCgroup: "4:memory:/elsewhere\n", mountinfo: container).directories,
                       ["/sys/fs/cgroup/memory"])
        // cgroup v2 mounted somewhere unusual, with a space in the path.
        let unified = "47 37 0:39 / /run/cg\\040two rw,relatime - cgroup2 cgroup2 rw\n"
        let v2 = SystemMemory.cgroupDirectories(procSelfCgroup: "0::/user.slice\n", mountinfo: unified)
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v2.directories, ["/run/cg two/user.slice", "/run/cg two"])
        // Hybrid: the v1 memory mount wins over the v2 one, as before.
        let hybrid = shared.replacingOccurrences(of: "cpu,memory", with: "memory") + unified
        XCTAssertEqual(SystemMemory.cgroupDirectories(procSelfCgroup: "4:memory:/x\n0::/\n", mountinfo: hybrid).directories,
                       ["/sys/fs/cgroup/memory/x", "/sys/fs/cgroup/memory"])
        // Lines that aren't cgroup mounts are skipped.
        XCTAssertEqual(SystemMemory.cgroupMounts(mountinfo: "22 1 8:1 / / rw - ext4 /dev/sda1 rw\nbroken\n").memory, nil)
    }

    func testCgroupLimitsAndHeadroom() {
        XCTAssertNil(SystemMemory.cgroupLimitValue("max\n", version: 2))
        XCTAssertEqual(SystemMemory.cgroupLimitValue("6272172032\n", version: 2), 6_272_172_032)
        XCTAssertEqual(SystemMemory.cgroupLimitValue("6272172032\n", version: 1), 6_272_172_032)
        XCTAssertNil(SystemMemory.cgroupLimitValue("9223372036854771712\n", version: 1))
        XCTAssertNil(SystemMemory.cgroupLimitValue("lots", version: 2))
        XCTAssertEqual(SystemMemory.inactiveFile(memoryStat: "anon 1\nfile 2\ninactive_file 300\n", version: 2), 300)
        XCTAssertEqual(SystemMemory.inactiveFile(memoryStat: "inactive_file 5\ntotal_inactive_file 7\n", version: 1), 7)
        XCTAssertEqual(SystemMemory.inactiveFile(memoryStat: "anon 1\n", version: 2), 0)

        let gb = 1 << 30
        // The process's own cgroup sets 6 GB, the root none: 1 GB in use, a tenth of it cache.
        let own = SystemMemory.CgroupLevel(limit: 6 * gb, usage: gb, inactiveFile: gb / 10)
        let root = SystemMemory.CgroupLevel(limit: nil, usage: 8 * gb, inactiveFile: 0)
        XCTAssertEqual(SystemMemory.cgroupLimit([own, root])?.limit, 6 * gb)
        XCTAssertEqual(SystemMemory.cgroupLimit([own, root])?.available, 6 * gb - (gb - gb / 10))
        // A parent with a lower limit and little headroom wins.
        let parent = SystemMemory.CgroupLevel(limit: 4 * gb, usage: 4 * gb - gb / 2, inactiveFile: 0)
        XCTAssertEqual(SystemMemory.cgroupLimit([own, parent, root])?.limit, 4 * gb)
        XCTAssertEqual(SystemMemory.cgroupLimit([own, parent, root])?.available, gb / 2)
        // Over the limit means no headroom, not a negative one; no limits means nil.
        XCTAssertEqual(SystemMemory.cgroupLimit([.init(limit: gb, usage: 2 * gb, inactiveFile: 0)])?.available, 0)
        XCTAssertNil(SystemMemory.cgroupLimit([root]))
    }

    func testTheRunningSystemReportsSomething() {
        XCTAssertGreaterThan(SystemMemory.total, 0)
        let available = SystemMemory.available()
        XCTAssertGreaterThan(available, 0)
        XCTAssertLessThanOrEqual(available, SystemMemory.total)
        XCTAssertTrue([0, 1, 2, 4].contains(SystemMemory.pressureLevel()))
    }
}
