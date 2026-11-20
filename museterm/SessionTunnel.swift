import Foundation
import Network

enum SessionTunnelPhase: String, Equatable {
    case starting
    case running
    case stopping
    case failed

    var occupiesTerminal: Bool {
        switch self {
        case .starting, .running, .stopping:
            return true
        case .failed:
            return false
        }
    }
}

struct SessionTunnelConfiguration: Equatable {
    static let minimumPort = 1
    static let maximumPort = 65_535

    var name: String
    var targetHost: String
    var targetPort: Int
    var localPort: Int

    var normalized: Self {
        Self(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            targetHost: targetHost.trimmingCharacters(in: .whitespacesAndNewlines),
            targetPort: targetPort,
            localPort: localPort
        )
    }

    var displayName: String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? L10n.string("session_tunnel.default_name") : clean
    }

    var localEndpoint: String {
        "127.0.0.1:\(localPort)"
    }

    var remoteEndpoint: String {
        Self.renderEndpoint(host: targetHost, port: targetPort)
    }

    func validated() throws -> Self {
        let clean = normalized
        guard !clean.targetHost.isEmpty else {
            throw SessionTunnelConfigurationError.missingTargetHost
        }
        guard Self.validPort(clean.targetPort) else {
            throw SessionTunnelConfigurationError.invalidTargetPort
        }
        guard Self.validPort(clean.localPort) else {
            throw SessionTunnelConfigurationError.invalidLocalPort
        }
        return clean
    }

    private static func validPort(_ port: Int) -> Bool {
        (minimumPort...maximumPort).contains(port)
    }

    private static func renderEndpoint(host: String, port: Int) -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.contains(":"), !cleanHost.hasPrefix("[") {
            return "[\(cleanHost)]:\(port)"
        }
        return "\(cleanHost):\(port)"
    }
}

enum SessionTunnelConfigurationError: LocalizedError, Equatable {
    case missingTargetHost
    case invalidTargetPort
    case invalidLocalPort

    var errorDescription: String? {
        switch self {
        case .missingTargetHost:
            return L10n.string("session_tunnel.error.missing_target_host")
        case .invalidTargetPort:
            return L10n.string("session_tunnel.error.invalid_target_port")
        case .invalidLocalPort:
            return L10n.string("session_tunnel.error.invalid_local_port")
        }
    }
}

enum SessionTunnelStartError: LocalizedError, Equatable {
    case processUnavailable
    case tunnelAlreadyActive
    case fileTransferActive

    var errorDescription: String? {
        switch self {
        case .processUnavailable:
            return L10n.string("session_tunnel.error.process_unavailable")
        case .tunnelAlreadyActive:
            return L10n.string("session_tunnel.error.already_active")
        case .fileTransferActive:
            return L10n.string("session_tunnel.error.file_transfer_active")
        }
    }
}

struct SessionTunnelClientSnapshot: Identifiable, Equatable {
    let id: UInt32
    let endpoint: String
    let connectedAt: Date
    var uploadedBytes: Int64
    var downloadedBytes: Int64
}

struct SessionTunnelStatus: Equatable {
    var phase: SessionTunnelPhase
    var configuration: SessionTunnelConfiguration
    var startedAt: Date?
    var uploadedBytes: Int64
    var downloadedBytes: Int64
    var clients: [SessionTunnelClientSnapshot]
    var errorMessage: String?

    var occupiesTerminal: Bool {
        phase.occupiesTerminal
    }

    var totalTransferredBytes: Int64 {
        uploadedBytes + downloadedBytes
    }

    static func starting(configuration: SessionTunnelConfiguration) -> Self {
        Self(
            phase: .starting,
            configuration: configuration,
            startedAt: nil,
            uploadedBytes: 0,
            downloadedBytes: 0,
            clients: [],
            errorMessage: nil
        )
    }
}

struct SessionTunnelProtocolMessage: Codable, Equatable {
    let version: Int
    let token: String
    let type: String
    let channel: UInt32?
    let data: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case token
        case type
        case channel
        case data
        case message
    }

    init(
        version: Int = 1,
        token: String,
        type: String,
        channel: UInt32? = nil,
        data: String? = nil,
        message: String? = nil
    ) {
        self.version = version
        self.token = token
        self.type = type
        self.channel = channel
        self.data = data
        self.message = message
    }
}

enum SessionTunnelFrameCodec {
    static let maximumBufferedBytes = 256 * 1024
    static let dataChunkBytes = 12 * 1024

    static func encode(_ message: SessionTunnelProtocolMessage) -> [UInt8]? {
        guard var data = try? JSONEncoder().encode(message) else { return nil }
        data.append(0x0A)
        return Array(data)
    }

    struct Decoder {
        private(set) var buffer: [UInt8] = []

        mutating func append(_ bytes: [UInt8]) -> [SessionTunnelProtocolMessage] {
            guard !bytes.isEmpty else { return [] }
            buffer.append(contentsOf: bytes)
            if buffer.count > SessionTunnelFrameCodec.maximumBufferedBytes {
                buffer.removeAll(keepingCapacity: true)
                return []
            }

            var messages: [SessionTunnelProtocolMessage] = []
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                var line = Array(buffer[..<newlineIndex])
                buffer.removeFirst(newlineIndex + 1)
                if line.last == 0x0D {
                    line.removeLast()
                }
                guard !line.isEmpty,
                      let message = try? JSONDecoder().decode(
                        SessionTunnelProtocolMessage.self,
                        from: Data(line)
                      ) else {
                    continue
                }
                messages.append(message)
            }
            return messages
        }
    }
}

enum SessionTunnelRemoteHelper {
    static let missingPythonMarker = "__MUSETERM_TUNNEL_PYTHON_MISSING__"
    private static let payloadChunkCharacterCount = 2_048

    static func bootstrapCommand(
        configuration: SessionTunnelConfiguration,
        token: String
    ) -> String {
        let launcher = loaderSource
        let arguments = [
            shellQuoted(configuration.targetHost),
            shellQuoted(String(configuration.targetPort)),
            shellQuoted(token)
        ].joined(separator: " ")
        let missingMarker = shellQuoted(missingPythonMarker)
        let missingToken = shellQuoted(token)
        let script = "if command -v python3 >/dev/null 2>&1; then exec python3 -c \(shellQuoted(launcher)) \(arguments); else printf '\\n%s%s\\n' \(missingMarker) \(missingToken); fi"
        return "/bin/sh -c \(shellQuoted(script))\n"
    }

    static func bootstrapInputBytes(
        configuration: SessionTunnelConfiguration,
        token: String
    ) -> [UInt8] {
        var bytes = Array(bootstrapCommand(configuration: configuration, token: token).utf8)
        if bytes.last == 0x0A {
            bytes[bytes.count - 1] = 0x0D
        }
        return bytes
    }

    static func helperPayloadFrames() -> [[UInt8]] {
        let encodedSource = Data(pythonSource.utf8).base64EncodedString()
        let chunks = stride(from: 0, to: encodedSource.count, by: payloadChunkCharacterCount).map {
            offset -> String in
            let start = encodedSource.index(encodedSource.startIndex, offsetBy: offset)
            let end = encodedSource.index(
                start,
                offsetBy: min(payloadChunkCharacterCount, encodedSource.count - offset)
            )
            return String(encodedSource[start..<end])
        }
        return [Array("\(chunks.count)\n".utf8)] + chunks.map { Array("\($0)\n".utf8) }
    }

    static func helperPayload() -> [UInt8] {
        helperPayloadFrames().flatMap { $0 }
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // 交互式 PTY 的 canonical input 通常会限制单行长度。先用一条短命令启动
    // loader 并切到 raw 模式，再分块传入完整助手，避免多跳终端截断超长命令。
    private static let loaderSource = #"import atexit,base64,json,os,sys,termios,tty;t=sys.argv[3];f=sys.stdin.fileno();s=termios.tcgetattr(f) if os.isatty(f) else None;s and (tty.setraw(f,termios.TCSANOW),atexit.register(termios.tcsetattr,f,termios.TCSANOW,s));print(json.dumps({"v":1,"token":t,"type":"loader_ready"},separators=(",",":")),flush=True);n=int(sys.stdin.buffer.readline());d=b"".join(sys.stdin.buffer.readline().strip() for _ in range(n));exec(base64.b64decode(d),{"MUSETERM_ORIGINAL_TTY":s})"#

    // 远端助手通过当前 PTY 运行，不落盘。raw 模式关闭 tty echo，JSONL + Base64
    // 让控制字符和任意 TCP 字节都能安全穿过多层交互式 SSH。
    static let pythonSource = #"""
import base64
import json
import os
import socket
import sys
import threading
import termios
import tty

HOST = sys.argv[1]
PORT = int(sys.argv[2])
TOKEN = sys.argv[3]
VERSION = 1
CHUNK = 12288
write_lock = threading.Lock()
sockets_lock = threading.Lock()
sockets = {}

def emit(kind, channel=None, data=None, message=None):
    payload = {"v": VERSION, "token": TOKEN, "type": kind}
    if channel is not None:
        payload["channel"] = channel
    if data is not None:
        payload["data"] = data
    if message is not None:
        payload["message"] = message
    encoded = (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")
    with write_lock:
        sys.stdout.buffer.write(encoded)
        sys.stdout.buffer.flush()

def remove_socket(channel):
    with sockets_lock:
        return sockets.pop(channel, None)

def close_channel(channel, notify=False):
    sock = remove_socket(channel)
    if sock is not None:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass
    if notify:
        emit("close", channel=channel)

def close_all():
    with sockets_lock:
        channels = list(sockets.keys())
    for channel in channels:
        close_channel(channel)

def pump_remote(channel, sock):
    try:
        while True:
            chunk = sock.recv(CHUNK)
            if not chunk:
                break
            emit("data", channel=channel, data=base64.b64encode(chunk).decode("ascii"))
    except OSError as error:
        emit("close", channel=channel, message=str(error))
    finally:
        close_channel(channel, notify=True)

def open_channel(channel):
    try:
        sock = socket.create_connection((HOST, PORT), timeout=10)
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        with sockets_lock:
            sockets[channel] = sock
        emit("opened", channel=channel)
        threading.Thread(target=pump_remote, args=(channel, sock), daemon=True).start()
    except OSError as error:
        emit("open_failed", channel=channel, message=str(error))

fd = sys.stdin.fileno()
saved_tty = globals().get("MUSETERM_ORIGINAL_TTY")
if saved_tty is None:
    saved_tty = termios.tcgetattr(fd) if os.isatty(fd) else None
    if saved_tty is not None:
        tty.setraw(fd, termios.TCSANOW)
try:
    emit("ready")
    while True:
        raw = sys.stdin.buffer.readline()
        if not raw:
            break
        try:
            frame = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if frame.get("v") != VERSION or frame.get("token") != TOKEN:
            continue
        kind = frame.get("type")
        channel = frame.get("channel")
        if kind == "open" and isinstance(channel, int):
            open_channel(channel)
        elif kind == "data" and isinstance(channel, int):
            with sockets_lock:
                sock = sockets.get(channel)
            if sock is not None:
                try:
                    sock.sendall(base64.b64decode(frame.get("data", ""), validate=True))
                except (OSError, ValueError) as error:
                    emit("close", channel=channel, message=str(error))
                    close_channel(channel)
        elif kind == "close" and isinstance(channel, int):
            close_channel(channel)
        elif kind == "ping":
            emit("pong")
        elif kind == "shutdown":
            break
finally:
    close_all()
    emit("stopped")
    if saved_tty is not None:
        termios.tcsetattr(fd, termios.TCSANOW, saved_tty)
"""#
}

final class SessionTunnelBridge {
    private enum RemoteHelperMode {
        case python
        case staticBinary(SessionTunnelHelperPlatform)
    }

    private final class Client {
        let channel: UInt32
        let connection: NWConnection
        var snapshot: SessionTunnelClientSnapshot
        var pendingLocalSends = 0
        var shouldCloseAfterLocalSends = false

        init(channel: UInt32, connection: NWConnection, endpoint: String) {
            self.channel = channel
            self.connection = connection
            snapshot = SessionTunnelClientSnapshot(
                id: channel,
                endpoint: endpoint,
                connectedAt: Date(),
                uploadedBytes: 0,
                downloadedBytes: 0
            )
        }
    }

    private let configuration: SessionTunnelConfiguration
    private let token: String
    private let queue = DispatchQueue(label: "im.some.museterm.session-tunnel")
    private let sendToRemote: ([UInt8]) -> Void
    private let onStatus: (SessionTunnelStatus) -> Void
    private let onFinished: (String?) -> Void
    private let shouldSendBootstrapCommand: Bool
    private let bundledHelperArtifact: (SessionTunnelHelperPlatform) -> SessionTunnelBundledHelper.Artifact?
    private var decoder = SessionTunnelFrameCodec.Decoder()
    private var missingMarkerBuffer = ""
    private var listener: NWListener?
    private var clients: [UInt32: Client] = [:]
    private var nextChannel: UInt32 = 1
    private var status: SessionTunnelStatus
    private var didFinish = false
    private var didSendHelperPayload = false
    private var didSelectRemoteHelper = false
    private var remoteHelperMode: RemoteHelperMode?
    private var pendingHelperPayload: [UInt8]?

    init(
        configuration: SessionTunnelConfiguration,
        token: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        shouldSendBootstrapCommand: Bool = true,
        bundledHelperArtifact: @escaping (SessionTunnelHelperPlatform) -> SessionTunnelBundledHelper.Artifact? = {
            SessionTunnelBundledHelper.artifact(for: $0)
        },
        sendToRemote: @escaping ([UInt8]) -> Void,
        onStatus: @escaping (SessionTunnelStatus) -> Void,
        onFinished: @escaping (String?) -> Void
    ) {
        self.configuration = configuration
        self.token = token
        self.shouldSendBootstrapCommand = shouldSendBootstrapCommand
        self.bundledHelperArtifact = bundledHelperArtifact
        self.sendToRemote = sendToRemote
        self.onStatus = onStatus
        self.onFinished = onFinished
        status = .starting(configuration: configuration)
    }

    func start() {
        publish(status)
        if shouldSendBootstrapCommand {
            // 隧道会独占当前 PTY。先清掉尚未提交的输入，再探测最深层服务器平台；
            // 平台响应回来后才选择对应静态助手，无法匹配时退回 Python 兼容路径。
            sendToRemote([0x03, 0x0D])
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.status.phase == .starting, !self.didFinish else { return }
                self.sendToRemote(
                    SessionTunnelBundledHelper.platformProbeInputBytes(token: self.token)
                )
            }
        }
        queue.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self, self.status.phase == .starting else { return }
            self.finish(error: L10n.string("session_tunnel.error.start_timeout"))
        }
    }

    func acceptRemoteData(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, !self.didFinish else { return }
            if let text = String(bytes: bytes, encoding: .utf8) {
                self.missingMarkerBuffer.append(text)
                self.missingMarkerBuffer = String(self.missingMarkerBuffer.suffix(512))
            }
            if self.missingMarkerBuffer.contains(
                SessionTunnelRemoteHelper.missingPythonMarker + self.token
            ) {
                self.finish(error: L10n.string("session_tunnel.error.helper_unavailable"))
                return
            }
            let messages = self.decoder.append(bytes)
            for message in messages where message.version == 1 && message.token == self.token {
                self.handle(message)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.status.phase = .stopping
            self.publish(self.status)
            self.listener?.cancel()
            self.listener = nil
            self.cancelAllClients(notifyRemote: true)
            self.send(type: "shutdown")
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.didFinish else { return }
                self.finish(error: nil)
            }
        }
    }

    func forceCancel(error: String?) {
        queue.async { [weak self] in
            self?.finish(error: error)
        }
    }

    private func handle(_ message: SessionTunnelProtocolMessage) {
        switch message.type {
        case "platform":
            handlePlatformProbe(message)
        case "loader_ready":
            guard status.phase == .starting, !didSendHelperPayload else { return }
            guard let pendingHelperPayload else { return }
            didSendHelperPayload = true
            sendToRemote(pendingHelperPayload)
        case "ready":
            guard status.phase == .starting else { return }
            startListener()
        case "opened":
            publishCurrentStatus()
        case "data":
            handleRemoteData(message)
        case "close":
            guard let channel = message.channel else { return }
            handleRemoteClose(channel: channel)
        case "open_failed":
            guard let channel = message.channel else { return }
            closeClient(channel: channel, notifyRemote: false)
        case "stopped":
            if case .staticBinary = remoteHelperMode {
                break
            }
            finish(error: nil)
        case "shell_ready":
            guard case .staticBinary = remoteHelperMode else { return }
            if message.data == "0" {
                finish(error: nil)
            } else {
                finish(error: L10n.string("session_tunnel.error.remote_helper"))
            }
        case "error":
            finish(error: message.message ?? L10n.string("session_tunnel.error.remote_helper"))
        case "pong":
            break
        default:
            break
        }
    }

    private func handlePlatformProbe(_ message: SessionTunnelProtocolMessage) {
        guard status.phase == .starting,
              !didSelectRemoteHelper,
              let probeData = message.data else {
            return
        }
        didSelectRemoteHelper = true

        if let platform = SessionTunnelHelperPlatform.detect(probeData: probeData),
           let artifact = bundledHelperArtifact(platform),
           !artifact.data.isEmpty {
            remoteHelperMode = .staticBinary(platform)
            let encodedPayload = SessionTunnelBundledHelper.helperPayload(artifact.data)
            pendingHelperPayload = encodedPayload
            sendToRemote(
                SessionTunnelBundledHelper.loaderInputBytes(
                    configuration: configuration,
                    token: token,
                    payloadByteCount: encodedPayload.count,
                    isGzipCompressed: artifact.isGzipCompressed
                )
            )
            return
        }

        remoteHelperMode = .python
        pendingHelperPayload = SessionTunnelRemoteHelper.helperPayload()
        sendToRemote(
            SessionTunnelRemoteHelper.bootstrapInputBytes(
                configuration: configuration,
                token: token
            )
        )
    }

    private func startListener() {
        do {
            guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.localPort)) else {
                finish(error: L10n.string("session_tunnel.error.invalid_local_port"))
                return
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = false
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            finish(error: L10n.format("session_tunnel.error.local_listener", error.localizedDescription))
        }
    }

    private func handleListenerState(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            status.phase = .running
            status.startedAt = Date()
            publish(status)
        case .failed(let error):
            finish(error: L10n.format("session_tunnel.error.local_listener", error.localizedDescription))
        case .cancelled:
            break
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard status.phase == .running else {
            connection.cancel()
            return
        }
        let channel = nextChannel
        nextChannel = nextChannel == UInt32.max ? 1 : nextChannel + 1
        let client = Client(
            channel: channel,
            connection: connection,
            endpoint: String(describing: connection.endpoint)
        )
        clients[channel] = client
        connection.stateUpdateHandler = { [weak self] connectionState in
            self?.queue.async {
                self?.handleConnectionState(connectionState, channel: channel)
            }
        }
        connection.start(queue: queue)
        publishCurrentStatus()
    }

    private func handleConnectionState(_ connectionState: NWConnection.State, channel: UInt32) {
        switch connectionState {
        case .ready:
            send(type: "open", channel: channel)
            receiveFromLocal(channel: channel)
        case .failed, .cancelled:
            closeClient(channel: channel, notifyRemote: true)
        default:
            break
        }
    }

    private func receiveFromLocal(channel: UInt32) {
        guard let client = clients[channel] else { return }
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: SessionTunnelFrameCodec.dataChunkBytes
        ) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, let current = self.clients[channel] else { return }
                if let data, !data.isEmpty {
                    current.snapshot.uploadedBytes += Int64(data.count)
                    self.status.uploadedBytes += Int64(data.count)
                    self.send(
                        type: "data",
                        channel: channel,
                        data: data.base64EncodedString()
                    )
                    self.publishCurrentStatus()
                }
                if isComplete || error != nil {
                    self.closeClient(channel: channel, notifyRemote: true)
                } else {
                    self.receiveFromLocal(channel: channel)
                }
            }
        }
    }

    private func handleRemoteData(_ message: SessionTunnelProtocolMessage) {
        guard let channel = message.channel,
              let encoded = message.data,
              let data = Data(base64Encoded: encoded),
              let client = clients[channel] else {
            return
        }
        client.snapshot.downloadedBytes += Int64(data.count)
        status.downloadedBytes += Int64(data.count)
        client.pendingLocalSends += 1
        client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self, let current = self.clients[channel] else { return }
                current.pendingLocalSends = max(0, current.pendingLocalSends - 1)
                if error != nil {
                    self.closeClient(channel: channel, notifyRemote: true)
                    return
                }
                if current.shouldCloseAfterLocalSends, current.pendingLocalSends == 0 {
                    self.closeClient(channel: channel, notifyRemote: false)
                }
            }
        })
        publishCurrentStatus()
    }

    private func handleRemoteClose(channel: UInt32) {
        guard let client = clients[channel] else { return }
        if client.pendingLocalSends > 0 {
            client.shouldCloseAfterLocalSends = true
            publishCurrentStatus()
            return
        }
        closeClient(channel: channel, notifyRemote: false)
    }

    private func closeClient(channel: UInt32, notifyRemote: Bool) {
        guard let client = clients.removeValue(forKey: channel) else { return }
        client.connection.cancel()
        if notifyRemote {
            send(type: "close", channel: channel)
        }
        publishCurrentStatus()
    }

    private func cancelAllClients(notifyRemote: Bool) {
        let channels = Array(clients.keys)
        for channel in channels {
            closeClient(channel: channel, notifyRemote: notifyRemote)
        }
    }

    private func send(
        type: String,
        channel: UInt32? = nil,
        data: String? = nil,
        message: String? = nil
    ) {
        let frame = SessionTunnelProtocolMessage(
            token: token,
            type: type,
            channel: channel,
            data: data,
            message: message
        )
        guard let bytes = SessionTunnelFrameCodec.encode(frame) else { return }
        sendToRemote(bytes)
    }

    private func publishCurrentStatus() {
        status.clients = clients.values
            .map(\.snapshot)
            .sorted { $0.connectedAt < $1.connectedAt }
        publish(status)
    }

    private func publish(_ status: SessionTunnelStatus) {
        DispatchQueue.main.async { [onStatus] in
            onStatus(status)
        }
    }

    private func finish(error: String?) {
        guard !didFinish else { return }
        didFinish = true
        listener?.cancel()
        listener = nil
        cancelAllClients(notifyRemote: false)
        DispatchQueue.main.async { [onFinished] in
            onFinished(error)
        }
    }
}
