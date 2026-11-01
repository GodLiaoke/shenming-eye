import Darwin
import Foundation

enum LocalAddressProvider {
    private struct P0 {
        let name: String
        let address: String

        var p1: Int {
            if name == "bridge100" { return 0 }
            if name == "en0" { return 1 }
            if name.hasPrefix("ap") { return 2 }
            if address.hasPrefix("172.20.10.") { return 3 }
            return 10
        }
    }

    static func currentIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var candidates: [P0] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addressPointer,
                socklen_t(addressPointer.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }
            candidates.append(P0(name: name, address: address))
        }
        return candidates.sorted { lhs, rhs in
            lhs.p1 == rhs.p1 ? lhs.name < rhs.name : lhs.p1 < rhs.p1
        }.first?.address
    }
}
