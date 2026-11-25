import AppKit
import Combine
import Darwin
import Foundation
import os

nonisolated struct PerformanceCPUTrigger {
    static let thresholdPercent = 30.0
    private static let sustainedTime = 3.0
    private static let startupGrace = 20.0
    private static let cooldown = 600.0
    private static let dailyWindow = 86_400.0
    private static let dailyLimit = 30
    private static let maxInterval = 2.5
    private static let maxCPUPercent = 12_800.0
    static var monotonicTime: TimeInterval {
        // Raw monotonic time advances during sleep, so samples cannot bridge a sleep gap.
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    struct Sample: Sendable {
        let uptime: TimeInterval
        let cpuSeconds: TimeInterval

        static func current() -> Self? {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            return Self(uptime: PerformanceCPUTrigger.monotonicTime, cpuSeconds: user + system)
        }
    }

    struct Episode: Sendable {
        let duration: TimeInterval
        let peak: Double
        let average: Double
    }

    private let startedAt: TimeInterval
    private var eligibleAt: TimeInterval
    private var previous: Sample?
    private var duration = 0.0
    private var peak = 0.0
    private var busySeconds = 0.0
    private var recentEpisodes: [TimeInterval] = []

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        eligibleAt = startedAt + Self.startupGrace
    }

    mutating func observe(_ sample: Sample?) -> Episode? {
        let baseline = previous
        previous = sample
        guard let sample, let baseline, baseline.uptime >= eligibleAt, sample.uptime >= startedAt else {
            clearEpisode()
            return nil
        }
        let elapsed = sample.uptime - baseline.uptime
        let cpu = sample.cpuSeconds - baseline.cpuSeconds
        guard elapsed > 0, elapsed <= Self.maxInterval, cpu >= 0 else {
            clearEpisode()
            return nil
        }
        let percent = min(cpu / elapsed * 100, Self.maxCPUPercent)
        guard percent > Self.thresholdPercent else {
            clearEpisode()
            return nil
        }
        duration += elapsed
        peak = max(peak, percent)
        busySeconds += percent / 100 * elapsed
        guard duration >= Self.sustainedTime else { return nil }
        let episode = Episode(duration: duration, peak: peak, average: busySeconds / duration * 100)
        recentEpisodes.removeAll { sample.uptime - $0 >= Self.dailyWindow }
        recentEpisodes.append(sample.uptime)
        eligibleAt = sample.uptime + Self.cooldown
        if recentEpisodes.count == Self.dailyLimit, let oldest = recentEpisodes.first {
            eligibleAt = max(eligibleAt, oldest + Self.dailyWindow)
        }
        resetBaseline()
        return episode
    }

    mutating func resetBaseline() {
        previous = nil
        clearEpisode()
    }

    private mutating func clearEpisode() {
        duration = 0
        peak = 0
        busySeconds = 0
    }
}

@MainActor
final class PerformanceWatchdog: ObservableObject {
    static let shared = PerformanceWatchdog()
    private static let installIDKey = "diagnostics.performanceInstallID"
    private nonisolated static let logger = Logger(subsystem: "im.some.museterm", category: "performance")
    private let surface = OSAllocatedUnfairLock(initialState: PerformanceSurface.background)
    private var preferences: TerminalPreferences?
    private var observation: AnyCancellable?
    private var hasLaunched = false
    private var enabled = false
    @Published private(set) var isDeleting = false
    @Published private(set) var hasInstallID: Bool
    private var worker: Task<Void, Never>?

    private init() {
        hasInstallID = UserDefaults.standard.string(forKey: Self.installIDKey).flatMap(UUID.init(uuidString:)) != nil
    }

    func observe(_ preferences: TerminalPreferences) {
        guard observation == nil, !Self.isTestHost else { return }
        self.preferences = preferences
        observation = preferences.$performanceReportsEnabled.removeDuplicates().sink { [weak self] enabled in
            self?.setEnabled(enabled)
        }
    }

    func start(isActive: Bool) {
        setActive(isActive)
        hasLaunched = true
        startIfNeeded()
    }

    func setActive(_ isActive: Bool) {
        surface.withLock { $0 = isActive ? .foreground : .background }
    }

    func stop() {
        hasLaunched = false
        worker?.cancel()
    }

    func deleteReports() async throws {
        guard !isDeleting, !Self.isTestHost, let id = storedInstallID else { return }
        isDeleting = true
        defer {
            isDeleting = false
            startIfNeeded()
        }
        preferences?.performanceReportsEnabled = false
        let activeWorker = worker
        activeWorker?.cancel()
        await activeWorker?.value
        try await PerformanceReportClient.live.delete(installID: id)
        // Keep the installation ID so the user can retry if the server had a late write.
    }

    private func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled { startIfNeeded() } else { worker?.cancel() }
    }

    private func startIfNeeded() {
        guard hasLaunched, enabled, worker == nil, !isDeleting else { return }
        let task = Task.detached(priority: .utility) { [surface] in
            await Self.run(surface: surface)
        }
        worker = task
        Task { [weak self] in
            await task.value
            self?.worker = nil
            self?.startIfNeeded()
        }
    }

    // Reuse the ID across reports and launches, and allocate it only once an incident is ready to send.
    private var storedInstallID: UUID? {
        UserDefaults.standard.string(forKey: Self.installIDKey).flatMap(UUID.init(uuidString:))
    }

    private func installIDForUpload() -> UUID? {
        guard enabled, hasLaunched, !isDeleting, !Task.isCancelled else { return nil }
        if let storedInstallID { return storedInstallID }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString.lowercased(), forKey: Self.installIDKey)
        hasInstallID = true
        return id
    }

    private func uploadIfEnabled(capturedAt: Date, surface: PerformanceSurface,
                                 episode: PerformanceCPUTrigger.Episode, stacks: String) async throws {
        guard let installID = installIDForUpload() else { return }
        let report = PerformanceReport(installID: installID, capturedAt: capturedAt, surface: surface,
                                       episode: episode, stacks: stacks)
        // Let an already dispatched request drain so deletion can run after it, in server order.
        let delivery = Task.detached(priority: .utility) {
            guard await self.canDispatchReport else { return }
            try await PerformanceReportClient.live.upload(report)
        }
        try await delivery.value
    }

    private var canDispatchReport: Bool {
        enabled && hasLaunched && !isDeleting && worker?.isCancelled == false
    }

    private static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["MUSETERM_AGENT_TEST_TOOL_ROOT"] != nil
            || environment["MUSETERM_UI_TEST_RUNTIME"] != nil
    }

    private nonisolated static func run(surface: OSAllocatedUnfairLock<PerformanceSurface>) async {
        var trigger = PerformanceCPUTrigger(startedAt: PerformanceCPUTrigger.monotonicTime)
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let episode = trigger.observe(.current()) else { continue }
            let capturedAt = Date()
            let capturedSurface = surface.withLock { $0 }
            do {
                guard let stacks = try await PerformanceStackCapture.capture() else {
                    logger.notice("Performance sample produced no usable call graph")
                    continue
                }
                try await shared.uploadIfEnabled(capturedAt: capturedAt, surface: capturedSurface,
                                                 episode: episode, stacks: stacks)
            } catch {
                if Task.isCancelled { return }
                // Keep logs free of request bodies, IDs, URLs with parameters, and local file paths.
                if case PerformanceReportClient.Failure.httpStatus(let status) = error {
                    logger.notice("Performance report rejected with HTTP \(status, privacy: .public)")
                } else {
                    logger.notice("Performance report capture or delivery failed")
                }
            }
            trigger.resetBaseline()
        }
    }
}
