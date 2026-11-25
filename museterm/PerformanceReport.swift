import Foundation

nonisolated enum PerformanceSurface: String, Sendable {
    case foreground = "museterm.foreground"
    case background = "museterm.background"
}

nonisolated struct PerformanceReport: Encodable, Sendable {
    let reportID = UUID().uuidString.lowercased()
    let installID: String
    let appID = SomeIMUpdateConfiguration.appID
    let appVersion = AppVersion.value
    let build: String?
    let osVersion: String
    let arch: String
    let locale: String?
    let capturedAt: Date
    let activeSurface: PerformanceSurface.RawValue
    let thresholdPercent = PerformanceCPUTrigger.thresholdPercent
    let sustainedSeconds: Double
    let peakCPUPercent: Double
    let averageCPUPercent: Double
    let sampleDurationSeconds = PerformanceStackCapture.durationSeconds
    let callStacksFormat = "macos-sample-v1"
    let callStacks: String

    init(installID: UUID, capturedAt: Date, surface: PerformanceSurface, episode: PerformanceCPUTrigger.Episode, stacks: String) {
        self.installID = installID.uuidString.lowercased()
        self.capturedAt = capturedAt
        activeSurface = surface.rawValue
        sustainedSeconds = episode.duration
        peakCPUPercent = episode.peak
        averageCPUPercent = episode.average
        callStacks = stacks
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #else
        arch = "unknown"
        #endif
        locale = Bundle.main.preferredLocalizations.first
    }

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case installID = "install_id"
        case appID = "app_id"
        case appVersion = "app_version"
        case build, arch, locale
        case osVersion = "os_version"
        case capturedAt = "captured_at"
        case activeSurface = "active_surface"
        case thresholdPercent = "threshold_percent"
        case sustainedSeconds = "sustained_seconds"
        case peakCPUPercent = "peak_cpu_percent"
        case averageCPUPercent = "average_cpu_percent"
        case sampleDurationSeconds = "sample_duration_seconds"
        case callStacksFormat = "call_stacks_format"
        case callStacks = "call_stacks"
    }
}

nonisolated struct PerformanceReportClient: Sendable {
    static let endpoint = URL(string: "https://og.niuwoai.com/api/v1/public/telemetry/perf-reports")!
    static let forgetEndpoint = endpoint.deletingLastPathComponent().appendingPathComponent("forget")
    static let live = Self()
    private static let maximumReceiptBytes = 8 * 1024
    private let session: URLSession

    init(session: URLSession = makeSession()) {
        self.session = session
    }

    func upload(_ report: PerformanceReport) async throws {
        let (data, status) = try await post(report, to: Self.endpoint)
        guard status == 200 || status == 202 else { throw Failure.httpStatus(status) }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.code == 0, receipt.accepted, receipt.reportID == report.reportID else {
            throw Failure.invalidReceipt
        }
    }

    func delete(installID: UUID) async throws {
        let (data, status) = try await post(ForgetRequest(install_id: installID.uuidString.lowercased()), to: Self.forgetEndpoint)
        guard status == 200 else { throw Failure.httpStatus(status) }
        guard let receipt = try? JSONDecoder().decode(ForgetReceipt.self, from: data), receipt.code == 0 else {
            throw Failure.invalidReceipt
        }
    }

    private func post(_ payload: some Encodable, to url: URL) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidReceipt }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumReceiptBytes else { throw Failure.invalidReceipt }
            data.append(byte)
        }
        return (data, response.statusCode)
    }

    static func makeSession() -> URLSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 30
        return URLSession(configuration: settings, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    enum Failure: Error, Equatable {
        case httpStatus(Int)
        case invalidReceipt
    }

    private struct Receipt: Decodable {
        let code: Int
        let accepted: Bool
        let reportID: String

        enum CodingKeys: String, CodingKey {
            case code, accepted
            case reportID = "report_id"
        }
    }

    private struct ForgetRequest: Encodable { let install_id: String }
    private struct ForgetReceipt: Decodable { let code: Int }
}
