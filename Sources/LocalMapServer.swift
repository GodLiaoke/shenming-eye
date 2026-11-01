import Foundation
import Network

/// S1：把打包进 App 的 9 张地图直接本地服务，让雷达页秒出图、离线也能看见底图。
///
/// 设计边界（重要）：
///  · 只服务 App 包内 `Resources/Maps/*.png` —— **不加载任何解码逻辑、不接触任何密钥**；
///  · 只监听回环（127.0.0.1）、随机端口，不对外暴露；
///  · 地图清单（manifest，几十字节）仍从云端取，保证换图不用重发版本时清单能更新。
final class LocalMapServer {
    static let shared = LocalMapServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "phoenix.localmap")
    private(set) var port: UInt16 = 0
    private(set) var ready = false

    /// 页面注入用的基地址；未就绪时为 nil（此时页面照旧走云端，不影响功能）。
    var baseURL: String? {
        guard ready, port != 0 else { return nil }
        return "http://127.0.0.1:\(port)"
    }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑回环，杜绝局域网内其它设备访问
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = listener.port?.rawValue ?? 0
                    self?.ready = self?.port != 0
                case .failed, .cancelled:
                    self?.ready = false
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            ready = false
        }
    }

    // MARK: - 极简 HTTP/1.1

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            // "GET /map-1-ascent.png HTTP/1.1"
            let parts = line.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"
            let body = self.file(for: path)
            let response = self.httpResponse(body: body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// 目录穿越防护：只接受纯文件名，且必须是包内确实存在的资源。
    private func file(for path: String) -> Data? {
        var name = path
        if let q = name.firstIndex(of: "?") { name = String(name[name.startIndex..<q]) }
        name = (name as NSString).lastPathComponent
        guard !name.isEmpty, !name.contains(".."), !name.contains("/") else { return nil }

        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        let url = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "Maps")
            ?? Bundle.main.url(forResource: stem, withExtension: ext)
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data
    }

    private func httpResponse(body: Data?) -> Data {
        if let body {
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: image/png\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Cache-Control: public, max-age=86400\r\n"
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + body
        }
        let head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        return Data(head.utf8)
    }
}
