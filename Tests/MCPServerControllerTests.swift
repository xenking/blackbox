import Foundation
import Testing

@testable import Blackbox

@Suite("MCP server controller")
struct MCPServerControllerTests {
  /// The shape `blackbox-mcp status --json` prints (pinned on the Rust side by
  /// `status_json_keys_are_the_contract_with_the_app`). A renamed key there fails here.
  @Test("status decodes the binary's JSON")
  func decodesStatus() throws {
    let json = """
      {"installed":true,"loaded":true,"healthy":false,"port":47817,
       "url":"http://127.0.0.1:47817/mcp","binary":"/Applications/Blackbox.app/Contents/MacOS/blackbox-mcp",
       "binary_exists":true,"token_file":"/t","log_file":"/l"}
      """
    let status = try JSONDecoder().decode(MCPServerController.Status.self, from: Data(json.utf8))
    #expect(status.installed && status.loaded && !status.healthy)
    #expect(status.port == 47817 && status.binaryExists)
    #expect(status.logFile == "/l")
  }

  @Test("a not-installed status has no port, url or binary")
  func decodesNotInstalled() throws {
    let json = """
      {"installed":false,"loaded":false,"healthy":false,"port":null,"url":null,"binary":null,
       "binary_exists":false,"token_file":"/t","log_file":"/l"}
      """
    let status = try JSONDecoder().decode(MCPServerController.Status.self, from: Data(json.utf8))
    #expect(!status.installed && status.port == nil && status.url == nil && status.binary == nil)
  }
}
