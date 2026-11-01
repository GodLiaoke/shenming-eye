import CodevMobile
import Foundation

struct LocalCodeVAccess: Equatable {
    let proxyUsername: String
    let proxyPassword: String
    let panelToken: String
    let panelURL: URL
}

enum LocalCodeVEngineError: LocalizedError {
    case startFailed(String)
    case malformedCredential
    case healthCheckTimedOut

    var errorDescription: String? {
        switch self {
        case let .startFailed(detail):
            return detail.isEmpty ? "算法服务启动失败" : "算法服务启动失败：\(detail)"
        case .malformedCredential:
            return "算法服务凭据无效，请重试"
        case .healthCheckTimedOut:
            return "算法服务启动超时"
        }
    }
}

/// In-process bridge to the bundled CodeV live proxy engine.
///
/// iOS sandboxes forbid spawning `codev-net`, so the SOCKS5 proxy, capture
/// pipeline and loopback radar panel all run inside this process via the
/// `CodevMobile` static library.  The server is contacted only for card
/// verification; decoding happens entirely on-device.
@MainActor
final class LocalCodeVEngine {
    static let shared = LocalCodeVEngine()

    static let proxyPort = 2_025
    static let panelPort = 18_080

    private(set) var isRunning = false
    private var access: LocalCodeVAccess?

    /// 当前进程引擎的内部凭据；单机游戏模式由扩展运行独立引擎。
    var currentAccess: LocalCodeVAccess? { access }

    private init() {}

    func start(advertisedHost: String) async throws -> LocalCodeVAccess {
        if isRunning, let access {
            return access
        }
        codev_engine_stop()

        let directory = try Self.dataDirectory()
        let host = advertisedHost.isEmpty ? "127.0.0.1" : advertisedHost

        guard let raw = codev_engine_start(directory.path, host) else {
            throw LocalCodeVEngineError.startFailed("engine returned null")
        }
        let payload = String(cString: raw)
        codev_engine_string_free(raw)

        let parsed = try Self.parse(payload)
        do {
            try await waitUntilHealthy(panelURL: parsed.panelURL)
        } catch {
            codev_engine_stop()
            throw error
        }
        access = parsed
        isRunning = true
        return parsed
    }

    func stop() {
        codev_engine_stop()
        access = nil
        isRunning = false
    }

    static func parse(_ payload: String) throws -> LocalCodeVAccess {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw LocalCodeVEngineError.malformedCredential
        }
        if (object["ok"] as? Bool) != true {
            throw LocalCodeVEngineError.startFailed((object["error"] as? String) ?? "unknown error")
        }
        guard let username = object["username"] as? String,
              let password = object["password"] as? String,
              let panelToken = object["panelToken"] as? String,
              let panelURLString = object["panelURL"] as? String,
              let panelURL = URL(string: panelURLString),
              !username.isEmpty, !password.isEmpty, !panelToken.isEmpty else {
            throw LocalCodeVEngineError.malformedCredential
        }
        return LocalCodeVAccess(
            proxyUsername: username,
            proxyPassword: password,
            panelToken: panelToken,
            panelURL: panelURL
        )
    }

    private func waitUntilHealthy(panelURL: URL) async throws {
        let healthURL = panelURL.appendingPathComponent("api/v1/healthz")
        for _ in 0..<60 {
            var request = URLRequest(url: healthURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 0.5
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        }
        throw LocalCodeVEngineError.healthCheckTimedOut
    }

    private static func dataDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("Phoenix/LocalEngine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
