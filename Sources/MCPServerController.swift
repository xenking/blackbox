import AppKit
import Foundation
import Observation
import SwiftUI

/// Drives the bundled `blackbox-mcp` binary's LaunchAgent subcommands. The binary owns every
/// decision (plist, token, launchctl); this only runs it and shows what it reports, so the
/// CLI and the Settings buttons cannot disagree.
@MainActor
@Observable
final class MCPServerController {
  /// `blackbox-mcp status --json`. Field names are the binary's, pinned by a test on each side.
  struct Status: Decodable, Equatable {
    var installed: Bool
    var loaded: Bool
    var healthy: Bool
    var port: Int?
    var url: String?
    var binary: String?
    var binaryExists: Bool
    var tokenFile: String
    var logFile: String

    private enum CodingKeys: String, CodingKey {
      case installed, loaded, healthy, port, url, binary
      case binaryExists = "binary_exists"
      case tokenFile = "token_file"
      case logFile = "log_file"
    }
  }

  private(set) var status: Status?
  private(set) var isBusy = false
  var errorMessage: String?

  static var binaryURL: URL {
    Bundle.main.bundleURL.appending(path: "Contents/MacOS/blackbox-mcp")
  }

  static var isAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: binaryURL.path)
  }

  /// The installed agent runs a copy of the binary that is no longer this app's - the app was
  /// moved or replaced from another location - so it needs reinstalling to follow it.
  var pointsElsewhere: Bool {
    guard let status, status.installed, let binary = status.binary else { return false }
    return binary != Self.binaryURL.resolvingSymlinksInPath().path(percentEncoded: false)
  }

  func refresh() async {
    guard Self.isAvailable else { return }
    do {
      let output = try await Self.run(["status", "--json"])
      guard output.status == 0 else { throw MCPError.failed(output.text) }
      status = try JSONDecoder().decode(Status.self, from: Data(output.text.utf8))
    } catch {
      errorMessage = "Could not read MCP server status: \(error.localizedDescription)"
    }
  }

  func install() async {
    await perform(["install-agent"])
  }

  func uninstall() async {
    await perform(["uninstall-agent"])
  }

  /// Puts ready-to-paste client configuration on the clipboard. The token is referenced by
  /// file path, never inlined, so what lands on the pasteboard is not a secret.
  func copyClientSetup() async {
    do {
      let output = try await Self.run(["print-config"])
      guard output.status == 0 else { throw MCPError.failed(output.text) }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(output.text, forType: .string)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func perform(_ arguments: [String]) async {
    isBusy = true
    defer { isBusy = false }
    do {
      let output = try await Self.run(arguments)
      errorMessage =
        output.status == 0 ? nil : output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      errorMessage = error.localizedDescription
    }
    await refresh()
  }

  enum MCPError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
      switch self {
      case .failed(let text): text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
  }

  struct Output: Sendable {
    var status: Int32
    var text: String
  }

  /// Runs the bundled binary. On a dispatch queue rather than the Swift cooperative pool:
  /// `readDataToEndOfFile` and `waitUntilExit` block their thread.
  nonisolated static func run(_ arguments: [String]) async throws -> Output {
    let executable = await MainActor.run { binaryURL }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
          try process.run()
        } catch {
          continuation.resume(throwing: error)
          return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        continuation.resume(
          returning: Output(
            status: process.terminationStatus, text: String(decoding: data, as: UTF8.self)))
      }
    }
  }
}

struct MCPServerSection: View {
  @State private var controller = MCPServerController()

  var body: some View {
    Section("Local MCP Server") {
      Text(
        "Lets an AI agent (Claude Code, Codex, ...) search and read your transcripts. Read-only, listens on 127.0.0.1 only and requires a token that stays on this Mac."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if MCPServerController.isAvailable {
        HStack(spacing: 6) {
          Image(systemName: "circle.fill")
            .font(.caption2)
            .foregroundStyle(statusColor)
          Text(statusLine)
          Spacer()
        }

        HStack {
          Button(controller.status?.installed == true ? "Reinstall" : "Install") {
            Task { await controller.install() }
          }
          Button("Remove") { Task { await controller.uninstall() } }
            .disabled(controller.status?.installed != true)
          // Not gated on the agent: the stdio setup it prints needs no listener at all, and it
          // is the recommended one for the Codex app.
          Button("Copy Client Setup") { Task { await controller.copyClientSetup() } }
        }
        .disabled(controller.isBusy)

        if controller.pointsElsewhere {
          Text("The installed agent runs a different copy of Blackbox. Reinstall to use this one.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if let error = controller.errorMessage {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      } else {
        Text("This build does not include the MCP server.")
          .foregroundStyle(.secondary)
      }
    }
    .task { await controller.refresh() }
  }

  private var statusColor: Color {
    guard let status = controller.status, status.installed else { return .secondary }
    return status.healthy ? .green : .orange
  }

  private var statusLine: String {
    guard let status = controller.status else { return "Checking..." }
    guard status.installed else { return "Not installed" }
    if status.healthy, let url = status.url { return "Running at \(url)" }
    return "Installed, not responding - see ~/Library/Logs/Blackbox/mcp.log"
  }
}
