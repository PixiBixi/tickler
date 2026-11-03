import Foundation

/// Sessions of the Claude desktop app: one `local_<id>.json` per session under
/// `claude-code-sessions/<account>/<org>/`, mapping the desktop id to the CLI session id it wraps.
public struct DesktopSessionIndex: Sendable {
    struct Record: Decodable {
        let sessionId: String
        let cliSessionId: String?
    }

    let directory: URL

    public init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    ) {
        self.directory = directory
    }

    /// The desktop app only accepts this form in its `claude://code/continue` link.
    static func isDesktopSessionId(_ id: String) -> Bool {
        id.wholeMatch(of: /local_[A-Za-z0-9-]{1,64}/) != nil
    }

    public func desktopSessionId(wrapping cliSessionId: String) -> String? {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("local_") {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.cliSessionId == cliSessionId,
                  Self.isDesktopSessionId(record.sessionId)
            else { continue }
            return record.sessionId
        }
        return nil
    }

    static func continueURL(desktopSessionId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: desktopSessionId)]
        return components.url
    }
}

public protocol URLOpening: Sendable {
    func open(_ url: URL) throws
}

/// `/usr/bin/open` rather than NSWorkspace: the core links no AppKit.
public struct SystemURLOpener: URLOpening {
    let binary: URL

    public init(binary: URL = URL(fileURLWithPath: "/usr/bin/open")) {
        self.binary = binary
    }

    public func open(_ url: URL) throws {
        do {
            _ = try WezTermDriver.execute(binary, [url.absoluteString], timeout: 10)
        } catch let ResumeError.terminal(message) {
            throw ResumeError.desktopApp(message)
        }
    }
}
