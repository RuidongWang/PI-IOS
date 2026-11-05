import Foundation

/// 一次建连所拥有的全部资源。direct 的 transport 恒为 nil；借入的 bootstrap SSH 不由它关闭。
final class RACPConnection: @unchecked Sendable {
    let socket: any RACPSocket
    let route: ConnectionRoute
    let transport: SSHTransport?
    private let ownsTransport: Bool
    private let lock = NSLock()
    private var socketClosed = false
    private var transportClosed = false

    init(
        socket: any RACPSocket,
        route: ConnectionRoute,
        transport: SSHTransport? = nil,
        ownsTransport: Bool = true
    ) {
        self.socket = socket
        self.route = route
        self.transport = transport
        self.ownsTransport = ownsTransport
    }

    func closeSocket() async {
        let shouldClose = lock.withLock { () -> Bool in
            guard !socketClosed else { return false }
            socketClosed = true
            return true
        }
        guard shouldClose else { return }
        await socket.close()
    }

    func close() async {
        await closeSocket()
        let shouldCloseTransport = lock.withLock { () -> Bool in
            guard ownsTransport && !transportClosed else { return false }
            transportClosed = true
            return true
        }
        if shouldCloseTransport {
            await transport?.close()
        }
    }
}

protocol RACPConnectionFactory: Sendable {
    func makeConnection(
        route: ConnectionRoute,
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        suppliedTransport: SSHTransport?
    ) async throws -> RACPConnection
}

struct LiveRACPConnectionFactory: RACPConnectionFactory {
    func makeConnection(
        route: ConnectionRoute,
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        suppliedTransport: SSHTransport?
    ) async throws -> RACPConnection {
        switch route {
        case .direct:
            guard let direct = configuration.direct else {
                throw RACPConnectionError(category: .configuration)
            }
            let socket = try await DirectRACPWebSocket.connect(
                endpoint: direct.endpoint,
                bearerToken: configuration.deviceToken ?? "",
                certificateSHA256: direct.certificateSHA256
            )
            return RACPConnection(socket: socket, route: .direct)
        case .ssh:
            guard let hostPort = configuration.hostPort,
                  (1...65_535).contains(hostPort)
            else { throw RACPConnectionError(category: .configuration) }
            let ownsTransport = suppliedTransport == nil
            let ssh: SSHTransport
            if let suppliedTransport {
                ssh = suppliedTransport
            } else {
                guard let request = configuration.ssh else {
                    throw RACPConnectionError(category: .configuration)
                }
                ssh = try await SSHTransport.connect(request, confirmer: confirmer)
            }
            do {
                let channel = try await ssh.directTCPIP(port: hostPort)
                let socket = try await RACPWebSocket.connect(
                    on: channel,
                    bearerToken: configuration.deviceToken
                )
                return RACPConnection(
                    socket: socket,
                    route: .ssh,
                    transport: ssh,
                    ownsTransport: ownsTransport
                )
            } catch {
                if ownsTransport { await ssh.close() }
                throw error
            }
        }
    }
}
