//
//  NetworkMonitor.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var isConstrained: Bool = false

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")

    init() {
        self.monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = (path.status == .satisfied)
            let isExpensive = path.isExpensive
            let isConstrained = path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnline = isOnline
                self.isExpensive = isExpensive
                self.isConstrained = isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
