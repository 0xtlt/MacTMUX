import MacTMUXCore
import Foundation

@MainActor
final class ResourceMetricsStore {
    private let metricsClient: any ProcessMetricsProviding
    private var notifyChange: () -> Void

    private(set) var metricsBySessionID: [String: ProcessResourceMetrics] = [:]
    private(set) var errorMessage: String?

    init(metricsClient: any ProcessMetricsProviding, notifyChange: @escaping () -> Void = {}) {
        self.metricsClient = metricsClient
        self.notifyChange = notifyChange
    }

    func setNotifyChange(_ notifyChange: @escaping () -> Void) {
        self.notifyChange = notifyChange
    }

    func clear() {
        metricsBySessionID = [:]
        errorMessage = nil
        notifyChange()
    }

    func loadIfEnabled(for sessions: [TmuxSession], isEnabled: Bool) async {
        guard isEnabled else {
            clear()
            return
        }

        let pidPairs = sessions.compactMap { session -> (String, Int32)? in
            guard let activePanePID = session.activePanePID else {
                return nil
            }
            return (session.id, activePanePID)
        }

        guard !pidPairs.isEmpty else {
            clear()
            return
        }

        do {
            let metricsByPID = try await metricsClient.metrics(forRootPIDs: pidPairs.map(\.1))
            metricsBySessionID = Dictionary(uniqueKeysWithValues: pidPairs.compactMap { sessionID, pid in
                guard let metrics = metricsByPID[pid] else {
                    return nil
                }
                return (sessionID, metrics)
            })
            DiagnosticLog.write("metrics loaded count=\(metricsBySessionID.count)")
            errorMessage = nil
        } catch {
            metricsBySessionID = [:]
            errorMessage = readableMessage(error)
            DiagnosticLog.write("metrics failed error=\(readableMessage(error))")
        }
        notifyChange()
    }

    func metricsText(for session: TmuxSession, isEnabled: Bool) -> String? {
        guard isEnabled, let metrics = metricsBySessionID[session.id] else {
            return nil
        }
        return "CPU \(metrics.formattedCPU) · RAM \(metrics.formattedMemory)"
    }

    private func readableMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description.isEmpty ? "Unknown error." : description
        }
        return error.localizedDescription
    }
}
