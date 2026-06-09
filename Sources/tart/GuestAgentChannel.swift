import GRPC
import NIOPosix

/// Connects to a guest agent's gRPC endpoint over a VM's control socket, runs
/// `body` with the resulting channel, and closes the channel afterwards on both
/// the success and error paths.
///
/// The connection uses the process-wide singleton event loop group, which must
/// not be shut down, so there is no group lifecycle to manage here.
func withGuestAgentChannel<T>(
  unixDomainSocketPath socketPath: String,
  _ body: (GRPCChannel) async throws -> T
) async throws -> T {
  let channel = try GRPCChannelPool.with(
    target: .unixDomainSocket(socketPath),
    transportSecurity: .plaintext,
    eventLoopGroup: .singletonMultiThreadedEventLoopGroup,
  )

  do {
    let result = try await body(channel)
    try await channel.close().get()
    return result
  } catch {
    try? await channel.close().get()
    throw error
  }
}
