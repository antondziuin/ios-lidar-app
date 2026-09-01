import Foundation
import Network

final class StreamClient {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onBytesSent: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "lidar.stream.client")
    private var connection: NWConnection?
    private var pendingBody: Data?
    private var sending = false
    private var userStopped = false
    private var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            let snapshot = state
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(snapshot)
            }
        }
    }

    func connect(host: String, port: UInt16) {
        queue.async { [weak self] in
            guard let self else { return }
            self.userStopped = false
            self.resetLocked()
            self.state = .connecting

            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.includePeerToPeer = true

            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 9000,
                using: parameters
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] newState in
                self?.queue.async {
                    guard let self, self.connection === connection else { return }
                    self.handle(newState)
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.userStopped = true
            self.resetLocked()
            self.state = .idle
        }
    }

    func sendFrame(_ body: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.state == .ready, self.connection != nil else { return }
            if self.sending {
                self.pendingBody = body
                return
            }
            self.write(body)
        }
    }

    private func handle(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .ready
        case .waiting:
            break
        case .failed(let error):
            let stopped = userStopped
            resetLocked()
            state = stopped ? .idle : .failed(error.localizedDescription)
        case .cancelled:
            if !userStopped {
                resetLocked()
                state = .idle
            }
        default:
            break
        }
    }

    private func write(_ body: Data) {
        guard let connection else { return }
        sending = true
        let packet = FrameCodec.packet(body: body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self, self.connection === connection else { return }
                self.sending = false
                if let error {
                    self.resetLocked()
                    self.state = .failed(error.localizedDescription)
                    return
                }
                self.onBytesSent?(packet.count)
                if let pending = self.pendingBody {
                    self.pendingBody = nil
                    self.write(pending)
                }
            }
        })
    }

    private func resetLocked() {
        pendingBody = nil
        sending = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }
}
