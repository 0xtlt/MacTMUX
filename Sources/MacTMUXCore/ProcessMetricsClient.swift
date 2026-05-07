import Foundation

public actor ProcessMetricsClient {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func metrics(forRootPIDs rootPIDs: [Int32]) async throws -> [Int32: ProcessResourceMetrics] {
        let uniqueRootPIDs = Array(Set(rootPIDs))
        guard !uniqueRootPIDs.isEmpty else {
            return [:]
        }

        let result = try await runner.run(Self.psCommand())
        if result.exitCode != 0 {
            throw MacTMUXError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return Self.aggregate(records: Self.parseProcessRecords(result.stdout), rootPIDs: uniqueRootPIDs)
    }

    public static func psCommand() -> CommandSpec {
        CommandSpec(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,%cpu=,rss="]
        )
    }

    public static func parseProcessRecords(_ output: String) -> [ProcessRecord] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ProcessRecord? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count == 4,
                      let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]),
                      let cpu = Double(parts[2]),
                      let rssKilobytes = Int64(parts[3]) else {
                    return nil
                }
                return ProcessRecord(pid: pid, parentPID: ppid, cpuPercent: cpu, residentMemoryKilobytes: rssKilobytes)
            }
    }

    public static func aggregate(records: [ProcessRecord], rootPIDs: [Int32]) -> [Int32: ProcessResourceMetrics] {
        let recordsByPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
        let childrenByParent = Dictionary(grouping: records, by: \.parentPID)

        return Dictionary(uniqueKeysWithValues: rootPIDs.map { rootPID in
            var visited = Set<Int32>()
            var stack = [rootPID]
            var cpuPercent = 0.0
            var residentMemoryKilobytes: Int64 = 0

            while let pid = stack.popLast() {
                guard visited.insert(pid).inserted else {
                    continue
                }

                if let record = recordsByPID[pid] {
                    cpuPercent += record.cpuPercent
                    residentMemoryKilobytes += record.residentMemoryKilobytes
                }

                stack.append(contentsOf: childrenByParent[pid]?.map(\.pid) ?? [])
            }

            return (
                rootPID,
                ProcessResourceMetrics(
                    cpuPercent: cpuPercent,
                    residentMemoryBytes: residentMemoryKilobytes * 1024
                )
            )
        })
    }
}

public struct ProcessRecord: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var cpuPercent: Double
    public var residentMemoryKilobytes: Int64

    public init(pid: Int32, parentPID: Int32, cpuPercent: Double, residentMemoryKilobytes: Int64) {
        self.pid = pid
        self.parentPID = parentPID
        self.cpuPercent = cpuPercent
        self.residentMemoryKilobytes = residentMemoryKilobytes
    }
}
