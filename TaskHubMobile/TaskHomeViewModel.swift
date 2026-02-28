import SwiftUI
import Combine

enum TaskListScope: Int, CaseIterable {
    case all = 0
    case work = 1
    case personal = 2

    var title: String {
        switch self {
        case .all: return "All"
        case .work: return "Work"
        case .personal: return "Personal"
        }
    }
}

enum ToastStyle {
    case info
    case success
    case error
}

struct InAppToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let style: ToastStyle
}

@MainActor
final class TaskHomeViewModel: ObservableObject {
    @Published var selectedScope: TaskListScope
    @Published var isPresentingQuickAdd = false
    @Published var toast: InAppToast?

    private let defaults: UserDefaults
    private let scopeKey = "task.home.scope"
    private var dismissTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.integer(forKey: scopeKey)
        self.selectedScope = TaskListScope(rawValue: raw) ?? .all
    }

    func setScope(_ scope: TaskListScope) {
        guard selectedScope != scope else { return }
        selectedScope = scope
        defaults.set(scope.rawValue, forKey: scopeKey)
    }

    func showToast(_ message: String, style: ToastStyle = .info, duration: TimeInterval = 2.8) {
        dismissTask?.cancel()
        toast = InAppToast(message: message, style: style)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(DS.Motion.quick) {
                    self?.toast = nil
                }
            }
        }
    }

    deinit {
        dismissTask?.cancel()
    }
}
