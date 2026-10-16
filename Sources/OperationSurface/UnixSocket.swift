import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 起動中のアプリの操作面に、別のプロセス(MCP の中継など)からつなぐための Unix ドメインソケット。
/// 1 行 1 メッセージ(JSON-RPC)でやり取りする。ネットワークには出ず、ソケットのファイルは本人だけが読み書きできる(0600)。
///
/// GUI を持つソフトは「操作面を持ち、このソケットで受け付ける」だけで、MCP クライアントから
/// 振り分け(MCPRouter。起動中ならソケットの先へ、居なければ自分で処理)を通して操作できるようになる
public final class UnixSocketServer {
    public enum ServerError: Error, CustomStringConvertible {
        case inUse(String)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .inUse(let p): return "ソケットは別のプロセスが使っています: \(p)"
            case .system(let what, let code): return "\(what) に失敗しました: \(String(cString: strerror(code)))"
            }
        }
    }

    /// 1 つの接続の中で、受け取った 1 行を処理して返す行を返す(返さないときは nil)
    public typealias LineHandler = (String) -> String?

    public let path: String
    private let handlerQueue: DispatchQueue
    private let newConnection: () -> LineHandler
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var clientFDs: Set<Int32> = []

    /// - handlerQueue: 行の処理を行う直列キュー(操作面は 1 つのキューからだけ使う決まりなので、全接続で同じキューにする)
    /// - newConnection: 接続ごとに処理を作る(接続ごとの状態を持てるように)
    public init(path: String, handlerQueue: DispatchQueue, newConnection: @escaping () -> LineHandler) {
        self.path = path
        self.handlerQueue = handlerQueue
        self.newConnection = newConnection
    }

    deinit { stop() }

    public func start() throws {
        // 前回の起動で残ったソケットのファイルは消す。ただし今つながる(別のプロセスが使っている)なら消さない
        if FileManager.default.fileExists(atPath: path) {
            if let fd = UnixSocketBridge.connect(path: path) {
                close(fd)
                throw ServerError.inUse(path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket", errno) }
        var addr = try UnixSocketBridge.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw ServerError.system("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); throw ServerError.system("listen", e) }
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        let fds = clientFDs
        clientFDs = []
        let l = listenFD
        listenFD = -1
        lock.unlock()
        for c in fds { shutdown(c, SHUT_RDWR); close(c) }
        if l >= 0 {
            shutdown(l, SHUT_RDWR)
            close(l)
            unlink(path)
        }
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listenFD >= 0
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // 止めた(stop で閉じた)
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            lock.lock(); clientFDs.insert(client); lock.unlock()
            let handler = newConnection()
            Thread.detachNewThread { [weak self] in
                UnixSocketBridge.readLines(client) { line in
                    guard let self else { return false }
                    var reply: String?
                    self.handlerQueue.sync { reply = handler(line) }
                    if let reply { return UnixSocketBridge.write(client, reply + "\n") }
                    return true
                }
                self?.lock.lock(); self?.clientFDs.remove(client); self?.lock.unlock()
                close(client)
            }
        }
    }
}

/// ソケットの小道具
public enum UnixSocketBridge {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw UnixSocketServer.ServerError.system("ソケットのパスが長すぎる", ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    /// つなぐ。つながらなければ nil(アプリが起動していない、受け付けがオフ)
    public static func connect(path: String) -> Int32? {
        guard FileManager.default.fileExists(atPath: path), var addr = try? address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(fd); return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// 1 行ずつ読む。onLine が false を返すか、相手が閉じたら終わる
    public static func readLines(_ fd: Int32, _ onLine: (String) -> Bool) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(contentsOf: buffer[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                if !onLine(line) { return }
            }
        }
        if !pending.isEmpty { _ = onLine(String(decoding: pending, as: UTF8.self)) }
    }

    @discardableResult
    public static func write(_ fd: Int32, _ text: String) -> Bool {
        let data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
