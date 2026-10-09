import Foundation
import MetricKit

/// Daily on-device reports from MetricKit: launch time, hangs, and crashes from real use.
/// iOS delivers them about once a day (not in the simulator unless simulated from Xcode's Debug menu).
/// Summaries stay on the device; nothing is sent anywhere unless the user shares the export.
struct DiagnosticsDay: Codable, Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    /// Median time to first frame, in milliseconds, when MetricKit reported launches.
    var launchMilliseconds: Double?
    var hangCount = 0
    var crashCount = 0
    var cpuExceptionCount = 0
    var diskWriteExceptionCount = 0
}

final class TaskFlowMetrics: NSObject, MXMetricManagerSubscriber {
    static let shared = TaskFlowMetrics()
    /// Launches under this feel instant; the goal for TaskFlow.
    static let launchGoalMilliseconds = 400.0

    private let queue = DispatchQueue(label: "TaskFlow.metrics", qos: .utility)
    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TaskFlow/Diagnostics", isDirectory: true)
    }
    private var summaryURL: URL { directory.appendingPathComponent("summary.json") }

    func start() {
        MXMetricManager.shared.add(self)
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        let days = payloads.map { payload in
            DiagnosticsDay(
                date: Calendar.current.startOfDay(for: payload.timeStampEnd),
                launchMilliseconds: payload.applicationLaunchMetrics.flatMap { Self.median(of: $0.histogrammedTimeToFirstDraw) },
                hangCount: payload.applicationResponsivenessMetrics.map { Self.total(of: $0.histogrammedApplicationHangTime) } ?? 0
            )
        }
        let raw = payloads.map { $0.jsonRepresentation() }
        queue.async { self.merge(days, raw: raw, prefix: "metrics") }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let days = payloads.map { payload in
            DiagnosticsDay(
                date: Calendar.current.startOfDay(for: payload.timeStampEnd),
                hangCount: payload.hangDiagnostics?.count ?? 0,
                crashCount: payload.crashDiagnostics?.count ?? 0,
                cpuExceptionCount: payload.cpuExceptionDiagnostics?.count ?? 0,
                diskWriteExceptionCount: payload.diskWriteExceptionDiagnostics?.count ?? 0
            )
        }
        let raw = payloads.map { $0.jsonRepresentation() }
        queue.async { self.merge(days, raw: raw, prefix: "diagnostics") }
    }

    // MARK: Storage

    /// The last 30 days, newest first.
    func recentDays() -> [DiagnosticsDay] {
        guard let data = try? Data(contentsOf: summaryURL),
              let days = try? JSONDecoder().decode([DiagnosticsDay].self, from: data) else { return [] }
        return days.sorted { $0.date > $1.date }
    }

    /// Raw MetricKit reports, for sharing with support or opening in Xcode.
    func exportFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func merge(_ incoming: [DiagnosticsDay], raw: [Data], prefix: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var byDay = Dictionary(recentDays().map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        for day in incoming {
            var current = byDay[day.date] ?? DiagnosticsDay(date: day.date)
            current.launchMilliseconds = day.launchMilliseconds ?? current.launchMilliseconds
            current.hangCount += day.hangCount
            current.crashCount += day.crashCount
            current.cpuExceptionCount += day.cpuExceptionCount
            current.diskWriteExceptionCount += day.diskWriteExceptionCount
            byDay[day.date] = current
        }
        let kept = byDay.values.sorted { $0.date > $1.date }.prefix(30)
        if let data = try? JSONEncoder().encode(Array(kept)) { try? data.write(to: summaryURL, options: .atomic) }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for (index, data) in raw.enumerated() {
            try? data.write(to: directory.appendingPathComponent("\(prefix)-\(stamp)-\(index).json"), options: .atomic)
        }
        // Keep the 20 newest raw reports.
        let reports = exportFiles().filter { $0.lastPathComponent != "summary.json" }
        for old in reports.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: Histogram math

    static func total<U: Foundation.Unit>(of histogram: MXHistogram<U>) -> Int {
        var count = 0
        let buckets = histogram.bucketEnumerator
        while let bucket = buckets.nextObject() as? MXHistogramBucket<U> { count += bucket.bucketCount }
        return count
    }

    /// Approximate median in milliseconds, using each bucket's midpoint.
    static func median(of histogram: MXHistogram<UnitDuration>) -> Double? {
        var buckets: [(midpoint: Double, count: Int)] = []
        let enumerator = histogram.bucketEnumerator
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
            let start = bucket.bucketStart.converted(to: .milliseconds).value
            let end = bucket.bucketEnd.converted(to: .milliseconds).value
            buckets.append(((start + end) / 2, bucket.bucketCount))
        }
        return medianMilliseconds(buckets)
    }

    static func medianMilliseconds(_ buckets: [(midpoint: Double, count: Int)]) -> Double? {
        let total = buckets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        var seen = 0
        for bucket in buckets.sorted(by: { $0.midpoint < $1.midpoint }) {
            seen += bucket.count
            if seen * 2 >= total { return bucket.midpoint }
        }
        return nil
    }
}
