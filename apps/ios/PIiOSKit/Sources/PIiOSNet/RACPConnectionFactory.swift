import Foundation
import NIOCore

/// 一次建连所拥有的全部资源。direct 的 transport 恒为 nil；借入的 bootstrap SSH 不由它关闭。
final class RACPConnection: @unchecked Sendable {
    let socket: any RACPSocket
    let route: ConnectionRoute
    let transport: SSHTransport?
    private let ownsTransport: Bool
    private let socketCloseTask = NetworkCloseTask()
    private let closeTask = NetworkCloseTask()

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
        await socketCloseTask.request { [self] in
            await socket.close()
        }.value
    }

    func close() async {
        await closeTask.request { [self] in
            await closeSocket()
            if ownsTransport {
                await transport?.close()
            }
        }.value
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
            var openedChannel: Channel?
            do {
                let channel = try await ssh.directTCPIP(port: hostPort)
                openedChannel = channel
                let socket = try await RACPWebSocket.connect(
                    on: channel,
                    lifecycle: ssh.lifecycle,
                    bearerToken: configuration.deviceToken
                )
                return RACPConnection(
                    socket: socket,
                    route: .ssh,
                    transport: ssh,
                    ownsTransport: ownsTransport
                )
            } catch {
                // A failed WebSocket handshake still owns this child channel. Close
                // only the child; a supplied SSH parent/group belongs to its owner.
                if let openedChannel {
                    await Self.closeChildChannel(openedChannel, lifecycle: ssh.lifecycle)
                }
                if ownsTransport { await ssh.close() }
                throw error
            }
        }
    }

    private static func closeChildChannel(
        _ channel: Channel,
        lifecycle: SSHConnectionLifecycle
    ) async {
        // Do not submit to a sealed/shut-down loop; the lifecycle owner is
        // already closing the parent and its children.
        guard lifecycle.executeCleanup({ channel.close(promise: nil) }) else { return }
        try? await channel.closeFuture.get()
    }
}
