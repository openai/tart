import Foundation
import Network
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
    try await withGuestAgentChannel(unixDomainSocketPath: controlSocketPath) { channel in
      // Invoke ResolveIP() gRPC method
      let callOptions = CallOptions(timeLimit: .timeout(.seconds(1)))
      let agentAsyncClient = AgentAsyncClient(channel: channel)
      let resolveIPCall = agentAsyncClient.makeResolveIpCall(ResolveIPRequest(), callOptions: callOptions)

      let response = try await resolveIPCall.response

      return IPv4Address(response.ip)
    }
  }
}
