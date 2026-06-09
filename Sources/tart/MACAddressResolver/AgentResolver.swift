import Foundation
import Network
import NIOPosix
import GRPC
import Cirruslabs_TartGuestAgent_Apple_Swift
import Cirruslabs_TartGuestAgent_Grpc_Swift

class AgentResolver {
  static func ResolveIP(_ controlSocketPath: String) async throws -> IPv4Address? {
    do {
      return try await resolveIP(controlSocketPath)
    } catch is GRPCConnectionPoolError {
      return nil
    }
  }

  private static func resolveIP(_ controlSocketPath: String) async throws -> IPv4Address? {
    // Create a gRPC channel connected to the VM's control socket
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
      try! group.syncShutdownGracefully()
    }

    let channel = try GRPCChannelPool.with(
      target: .unixDomainSocket(controlSocketPath),
      transportSecurity: .plaintext,
      eventLoopGroup: group,
    )
    defer {
      try! channel.close().wait()
    }

    // Invoke ResolveIP() gRPC method
    let callOptions = CallOptions(timeLimit: .timeout(.seconds(1)))
    let agentAsyncClient = AgentAsyncClient(channel: channel)
    let resolveIPCall = agentAsyncClient.makeResolveIpCall(ResolveIPRequest(), callOptions: callOptions)

    let response = try await resolveIPCall.response

    return IPv4Address(response.ip)
  }
}
