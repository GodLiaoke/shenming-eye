import Foundation

/// Swift-side redacted view of the Rust proxy self-check.
struct ProxyDiagnosticsSnapshot: Decodable, Equatable {
    struct Layer: Decodable, Equatable {
        let ok: Bool
        let detail: String
    }

    let ok: Bool
    let listener: Layer
    let socksHandshake: Layer
    let dns: Layer
    let tcp: Layer
    let udp: Layer
    let interfaceSummary: String?

    var isHealthy: Bool {
        ok && listener.ok && socksHandshake.ok && dns.ok && tcp.ok && udp.ok
    }

    var firstFailure: String? {
        let failures = [listener, socksHandshake, dns, tcp, udp]
            .first(where: { !$0.ok })
        return failures?.detail
    }

    init(json data: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        ok = envelope.ok
        listener = envelope.diagnostics.listener
        socksHandshake = envelope.diagnostics.socksHandshake
        dns = envelope.diagnostics.dns
        tcp = envelope.diagnostics.tcp
        udp = envelope.diagnostics.udp
        interfaceSummary = envelope.diagnostics.interfaceSummary
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let diagnostics: Diagnostics
    }

    private struct Diagnostics: Decodable {
        let listener: Layer
        let socksHandshake: Layer
        let dns: Layer
        let tcp: Layer
        let udp: Layer
        let interfaceSummary: String?

        enum CodingKeys: String, CodingKey {
            case listener
            case socksHandshake = "socks_handshake"
            case dns
            case tcp
            case udp
            case interfaceSummary = "interface"
        }
    }
}
