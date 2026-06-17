import Foundation

enum MacTMUXStoreErrorScope: String, Equatable {
    case tmux
    case terminal
    case logs
    case metrics
    case sessionAction
}

struct MacTMUXStoreError: Identifiable, Equatable {
    var scope: MacTMUXStoreErrorScope
    var message: String

    var id: String {
        "\(scope.rawValue):\(message)"
    }
}
