import Foundation

/// Finds boards announcing themselves on the local network
/// (`_wallboard._tcp`), and works out the address of each.
final class HubFinder: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Hub: Identifiable, Hashable {
        let name: String
        let url: String
        var id: String { url }
    }

    @Published var hubs: [Hub] = []
    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_wallboard._tcp.", inDomain: "local.")
    }

    func stop() { browser.stop() }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        pending.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let clean = host.hasSuffix(".") ? String(host.dropLast()) : host
        let hub = Hub(name: sender.name, url: "http://\(clean):\(sender.port)")
        DispatchQueue.main.async {
            if !self.hubs.contains(hub) { self.hubs.append(hub) }
        }
        pending.removeAll { $0 == sender }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        DispatchQueue.main.async { self.hubs.removeAll { $0.name == service.name } }
    }
}
