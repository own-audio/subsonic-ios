import Network
import Observation

/// Whether the phone has a network path at all. It can't tell a Wi-Fi with no internet from a
/// working one; short request timeouts and the saved answers cover that case.
@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isConnected = true
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isConnected != connected else { return }
                self.isConnected = connected
                self.onChange?(connected)
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}
