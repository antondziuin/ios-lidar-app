import ARKit
import Combine
import Foundation

final class ARSessionManager: ObservableObject {
    let session = ARSession()

    @Published var host: String = "192.168.1.10"
    @Published var port: String = "9000"
    @Published var isARRunning = false
    @Published var isStreaming = false
    @Published var isConnecting = false
    @Published var status: String = "Остановлено"
    @Published var stats: String = ""
    @Published var errorMessage: String?

    var isLiDARSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private let client = StreamClient()
    private let encoder = FrameEncoder()
    private let arQueue = DispatchQueue(label: "lidar.ar.session")
    private let encodeQueue = DispatchQueue(label: "lidar.encode", qos: .userInitiated)
    private let lock = NSLock()
    private var encoding = false
    private var streamingEnabled = false
    private var lastCaptureTime: TimeInterval = 0
    private let fpsInterval: TimeInterval = 1.0 / 12.0
    private var windowStart = Date()
    private var bytesWindow = 0
    private var framesWindow = 0
    private var delegateProxy: ARSessionDelegateProxy?

    init() {
        let proxy = ARSessionDelegateProxy(owner: self)
        delegateProxy = proxy
        session.delegate = proxy
        session.delegateQueue = arQueue

        client.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleClientState(state)
            }
        }
        client.onBytesSent = { [weak self] bytes in
            DispatchQueue.main.async {
                self?.noteSent(bytes: bytes)
            }
        }
    }

    func startCamera() {
        guard isLiDARSupported else {
            errorMessage = "LiDAR недоступен. Нужен iPhone с задним сканером (14 Pro Max и аналоги)."
            status = "Нет LiDAR"
            return
        }
        errorMessage = nil
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        isARRunning = true
        if !isStreaming {
            status = "Камера запущена"
        }
    }

    func stopCamera() {
        isARRunning = false
        stopStreaming()
        session.pause()
        status = "Остановлено"
    }

    func toggleStreaming() {
        if isStreaming || isConnecting {
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    func startStreaming() {
        errorMessage = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            errorMessage = "Укажите IP-адрес ПК"
            return
        }
        guard let portValue = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), portValue > 0 else {
            errorMessage = "Некорректный порт"
            return
        }
        if !isARRunning {
            startCamera()
        }
        isConnecting = true
        status = "Подключение…"
        client.connect(host: trimmedHost, port: portValue)
    }

    func stopStreaming() {
        lock.lock()
        streamingEnabled = false
        lock.unlock()
        isStreaming = false
        isConnecting = false
        client.disconnect()
        stats = ""
        if isARRunning {
            status = "Камера запущена"
        } else {
            status = "Остановлено"
        }
    }

    func handleFrame(_ frame: ARFrame) {
        lock.lock()
        let shouldStream = streamingEnabled
        let busy = encoding
        if shouldStream && !busy {
            encoding = true
        }
        lock.unlock()
        guard shouldStream, !busy else { return }

        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.encoding = false
                self.lock.unlock()
            }

            self.lock.lock()
            let elapsed = frame.timestamp - self.lastCaptureTime
            if self.lastCaptureTime != 0 && elapsed < self.fpsInterval {
                self.lock.unlock()
                return
            }
            self.lastCaptureTime = frame.timestamp
            self.lock.unlock()

            guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
            guard let body = self.encoder.encode(
                timestamp: frame.timestamp,
                capturedImage: frame.capturedImage,
                depthMap: depth.depthMap,
                confidenceMap: depth.confidenceMap,
                intrinsics: frame.camera.intrinsics,
                transform: frame.camera.transform
            ) else { return }
            self.client.sendFrame(body)
        }
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isAutoFocusEnabled = true
        config.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        return config
    }

    private func handleClientState(_ state: StreamClient.State) {
        switch state {
        case .idle:
            lock.lock()
            streamingEnabled = false
            lock.unlock()
            isStreaming = false
            isConnecting = false
            if isARRunning { status = "Камера запущена" }
        case .connecting:
            isConnecting = true
            status = "Подключение…"
        case .ready:
            lock.lock()
            streamingEnabled = true
            lastCaptureTime = 0
            lock.unlock()
            isConnecting = false
            isStreaming = true
            status = "Стрим идёт"
            errorMessage = nil
        case .failed(let message):
            lock.lock()
            streamingEnabled = false
            lock.unlock()
            isConnecting = false
            isStreaming = false
            errorMessage = message
            status = "Ошибка сети"
        }
    }

    private func noteSent(bytes: Int) {
        bytesWindow += bytes
        framesWindow += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1.0 {
            let fps = Double(framesWindow) / elapsed
            let kbps = Double(bytesWindow) / elapsed / 1024.0
            stats = String(format: "%.1f fps · %.0f КБ/с", fps, kbps)
            windowStart = Date()
            bytesWindow = 0
            framesWindow = 0
        }
    }
}

private final class ARSessionDelegateProxy: NSObject, ARSessionDelegate {
    weak var owner: ARSessionManager?

    init(owner: ARSessionManager) {
        self.owner = owner
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        owner?.handleFrame(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.owner?.errorMessage = error.localizedDescription
            self?.owner?.status = "Ошибка ARKit"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.owner?.status = "ARKit прерван"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.owner?.startCamera()
        }
    }
}
