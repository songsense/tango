import ArgumentParser
import Foundation
import ClaudeToolCore

struct Ask: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Send a prompt to the daemon and wait for a pat or button response. Prints the response and exits."
    )

    @Option(name: [.long, .customShort("p")], help: "Prompt text shown in the notification.")
    var prompt: String

    @Option(name: .long, help: "Seconds to wait for a response before timing out.")
    var timeout: Double = 180

    @Option(name: .long, help: "Optional tool name shown in the notification title.")
    var tool: String?

    @Option(name: .long, help: "Optional command shown in the notification body.")
    var command: String?

    func run() throws {
        let context: AskContext?
        if tool != nil || command != nil {
            context = AskContext(toolName: tool, command: command)
        } else {
            context = nil
        }
        let req = AskRequest(prompt: prompt, timeout: timeout, context: context)
        let client = SocketClient()
        do {
            let reply = try client.ask(req)
            print(reply.response.rawValue)
            if reply.response == .timeout {
                throw ExitCode(124)
            }
        } catch let err as SocketClientError {
            FileHandle.standardError.write(Data("\(err)\n".utf8))
            throw ExitCode(2)
        }
    }
}
