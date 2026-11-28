import Foundation
import notify

@MainActor
final class CallActivityMonitor {
    // On macOS, CallKit sets this Darwin notification's state while its call list is nonempty.
    // The first call posts a notification. Removing the last call can just clear the state.
    private let notificationName: String
    private var token = NOTIFY_TOKEN_INVALID
    private var endTimer: Timer?
    private var didChange: ((Bool) -> Void)?

    nonisolated init(notificationName: String = "com.apple.callkit.callcontroller.shouldconnect") {
        self.notificationName = notificationName
    }

    func start(_ didChange: @escaping (Bool) -> Void) {
        stop()
        var registration = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(notificationName, &registration, .main) { [weak self] token in
            MainActor.assumeIsolated {
                guard let self, self.token == token else { return }
                self.refresh()
            }
        }
        guard status == NOTIFY_STATUS_OK else { return }
        token = registration
        self.didChange = didChange
        refresh()
    }

    private func refresh() {
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return }
        let active = state != 0
        guard active != (endTimer != nil) else { return }
        if active {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.1
            endTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            endTimer?.invalidate()
            endTimer = nil
        }
        didChange?(active)
    }

    func stop() {
        endTimer?.invalidate()
        endTimer = nil
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token); token = NOTIFY_TOKEN_INVALID }
        didChange = nil
    }
}
