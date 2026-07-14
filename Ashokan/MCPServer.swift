import Cocoa
import Network

/// Ashokan's MCP server: lets any MCP-speaking agent (Claude Code, Codex, …)
/// list, read, and open documents — and propose edits that land as TRACKED
/// CHANGES for the human to accept or reject. Agents never get accept/reject;
/// adjudication is the user's.
///
/// Design constraints (Brant's law):
///  - OFF by default. When off, this object doesn't exist: no listener,
///    no queue, no cost.
///  - When on, nothing is added to the editing path beyond the one-integer
///    revision bump Document already does.
///
/// Transport: MCP streamable-HTTP (JSON-RPC 2.0 over POST) on 127.0.0.1
/// only, bearer-token auth. Optimistic concurrency via per-document
/// revision tokens (a stale write returns the current revision, never
/// applies).
final class MCPServer {
    static let enabledKey = "AshokanMCPEnabled"
    static let portKey = "AshokanMCPPort"
    static let tokenKey = "AshokanMCPToken"

    private static var _shared: MCPServer?
    /// Only ever instantiated when the feature is turned on.
    static var sharedIfRunning: MCPServer? { _shared }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        return stored > 0 ? UInt16(stored) : 8722
    }

    static var token: String {
        if let existing = UserDefaults.standard.string(forKey: tokenKey) { return existing }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(fresh, forKey: tokenKey)
        return fresh
    }

    static func startIfEnabled() {
        guard isEnabled, _shared == nil else { return }
        _shared = MCPServer()
        _shared?.start()
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled {
            startIfEnabled()
        } else {
            _shared?.stop()
            _shared = nil
        }
    }

    /// One-paste setup for Claude Code.
    static var setupCommand: String {
        "claude mcp add --transport http ashokan http://127.0.0.1:\(port)/mcp --header \"Authorization: Bearer \(token)\""
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.brantkuehn.ashokan.mcp")

    private func start() {
        do {
            let params = NWParameters.tcp
            // Bind explicitly to 127.0.0.1 — never a wildcard interface.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("Ashokan MCP: listening on 127.0.0.1:%d", Int(Self.port))
        } catch {
            NSLog("Ashokan MCP: failed to start — %@", error.localizedDescription)
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        NSLog("Ashokan MCP: stopped")
    }

    // MARK: - Minimal HTTP/1.1 handling (single request per connection)

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || buffer.count > (1 << 20) { connection.cancel(); return }
                self.receiveRequest(connection, buffer: buffer)
                return
            }
            let headerData = buffer[..<headerEnd.lowerBound]
            let header = String(data: headerData, encoding: .utf8) ?? ""
            let contentLength = header
                .components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let bodyStart = headerEnd.upperBound
            let haveBody = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
            if haveBody < contentLength && !complete {
                self.receiveRequest(connection, buffer: buffer)
                return
            }
            let body = buffer[bodyStart...].prefix(contentLength)
            self.route(connection, header: header, body: Data(body))
        }
    }

    private func route(_ connection: NWConnection, header: String, body: Data) {
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let method = requestLine.components(separatedBy: " ").first ?? ""

        func headerValue(_ name: String) -> String? {
            header.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }

        // Origin check (DNS-rebinding defense) + bearer auth on every request.
        if let origin = headerValue("Origin"),
           !(origin.contains("127.0.0.1") || origin.contains("localhost")) {
            respond(connection, status: "403 Forbidden", body: Data())
            return
        }
        guard headerValue("Authorization") == "Bearer \(Self.token)" else {
            respond(connection, status: "401 Unauthorized", body: Data())
            return
        }

        switch method {
        case "POST":
            handleJSONRPC(connection, body: body)
        case "GET":
            respond(connection, status: "405 Method Not Allowed", body: Data())
        case "DELETE":
            respond(connection, status: "200 OK", body: Data())
        default:
            respond(connection, status: "405 Method Not Allowed", body: Data())
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data,
                         contentType: String = "application/json") {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - JSON-RPC / MCP

    private func handleJSONRPC(_ connection: NWConnection, body: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = message["method"] as? String else {
            respond(connection, status: "400 Bad Request", body: Data())
            return
        }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications get 202 and no body.
        if id == nil {
            respond(connection, status: "202 Accepted", body: Data())
            return
        }

        Task { @MainActor in
            let result: [String: Any]
            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String ?? "2025-06-18"
                result = [
                    "protocolVersion": requested,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "ashokan", "version":
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                    "instructions": "Ashokan is the user's document editor. propose_edits lands your edits as TRACKED CHANGES (standard ins/del markup) for the human to accept or reject — never rewrite silently. Read a document to get its revision token; a propose with a stale revision is rejected with the current one. Quotes in edits must be exact substrings of the document's visible text (docText).",
                ]
            case "ping":
                result = [:]
            case "tools/list":
                result = ["tools": Self.toolDefinitions]
            case "tools/call":
                result = await self.callTool(params)
            default:
                self.sendRPC(connection, ["jsonrpc": "2.0", "id": id!,
                    "error": ["code": -32601, "message": "method not found: \(method)"]])
                return
            }
            self.sendRPC(connection, ["jsonrpc": "2.0", "id": id!, "result": result])
        }
    }

    private func sendRPC(_ connection: NWConnection, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        queue.async { self.respond(connection, status: "200 OK", body: data) }
    }

    // MARK: - Tools

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_documents",
            "description": "List the documents currently open in Ashokan, with their ids and revision tokens.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "read_document",
            "description": "Read one open document: its source (HTML body or Markdown), its visible text (docText — quotes for propose_edits must match this), and its current revision token.",
            "inputSchema": ["type": "object", "required": ["documentId"], "properties": [
                "documentId": ["type": "string"],
            ]],
        ],
        [
            "name": "propose_edits",
            "description": "Propose edits to an open document. Each edit is anchored to an exact quote from the document's visible text and lands as a TRACKED CHANGE (with your author name) plus an optional comment — the human accepts or rejects each one. Requires the document's current revision; if stale, nothing is applied and the current revision is returned.",
            "inputSchema": ["type": "object", "required": ["documentId", "revision", "edits", "author"], "properties": [
                "documentId": ["type": "string"],
                "revision": ["type": "integer", "description": "revision token from read_document"],
                "author": ["type": "string", "description": "your agent/model name, shown on every suggestion"],
                "edits": ["type": "array", "items": ["type": "object", "required": ["quote"], "properties": [
                    "quote": ["type": "string", "description": "exact contiguous text from docText (10-150 chars)"],
                    "replacement": ["type": "string", "description": "new text; omit for a comment-only annotation"],
                    "comment": ["type": "string", "description": "rationale or question, shown as a margin comment"],
                ]]],
            ]],
        ],
        [
            "name": "get_review_state",
            "description": "List a document's pending tracked changes and comments (with authors and anchor text) — useful to see what is already suggested before proposing more.",
            "inputSchema": ["type": "object", "required": ["documentId"], "properties": [
                "documentId": ["type": "string"],
            ]],
        ],
        [
            "name": "open_document",
            "description": "Open an HTML or Markdown file in Ashokan (e.g. a report you just wrote) so the user can see it. Returns the new document's id and revision.",
            "inputSchema": ["type": "object", "required": ["path"], "properties": [
                "path": ["type": "string", "description": "absolute path to an .html/.htm/.md/.markdown file"],
            ]],
        ],
    ]

    @MainActor
    private func callTool(_ params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let payload: Any
            switch name {
            case "list_documents": payload = try listDocuments()
            case "read_document": payload = try await readDocument(args)
            case "propose_edits": payload = try await proposeEdits(args)
            case "get_review_state": payload = try await reviewState(args)
            case "open_document": payload = try await openDocument(args)
            default: throw ToolError("unknown tool: \(name)")
            }
            let text = String(data: try JSONSerialization.data(withJSONObject: payload,
                                                               options: [.fragmentsAllowed]), encoding: .utf8) ?? "{}"
            return ["content": [["type": "text", "text": text]]]
        } catch let error as ToolError {
            return ["content": [["type": "text", "text": error.message]], "isError": true]
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    struct ToolError: Error { let message: String; init(_ m: String) { message = m } }

    @MainActor
    private func documents() -> [Document] {
        NSDocumentController.shared.documents.compactMap { $0 as? Document }
    }

    @MainActor
    private func document(_ args: [String: Any]) throws -> Document {
        guard let id = args["documentId"] as? String,
              let doc = documents().first(where: { $0.mcpId == id }) else {
            throw ToolError("DOCUMENT_NOT_FOUND: no open document with that id; call list_documents")
        }
        return doc
    }

    @MainActor
    private func controller(for doc: Document) throws -> DocumentWindowController {
        guard let wc = doc.windowControllers.first as? DocumentWindowController else {
            throw ToolError("DOCUMENT_NOT_READY: document has no window yet")
        }
        return wc
    }

    @MainActor
    private func evaluateJS(_ doc: Document, _ script: String) async throws -> Any? {
        let webView = try controller(for: doc).editorVC.webView
        return try await withCheckedThrowingContinuation { continuation in
            webView!.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result) }
            }
        }
    }

    @MainActor
    private func summary(_ doc: Document) -> [String: Any] {
        [
            "id": doc.mcpId,
            "title": doc.displayName ?? "Untitled",
            "path": doc.fileURL?.path ?? NSNull() as Any,
            "format": doc.format == .markdown ? "markdown" : "html",
            "revision": doc.revision,
        ]
    }

    @MainActor
    private func listDocuments() throws -> Any {
        ["documents": documents().map(summary)]
    }

    @MainActor
    private func readDocument(_ args: [String: Any]) async throws -> Any {
        let doc = try document(args)
        let docText = try await evaluateJS(doc, "window.Ashokan.getDocText()") as? String ?? ""
        var result = summary(doc)
        result["source"] = doc.format == .markdown ? doc.markdown : doc.model.bodyHTML
        result["docText"] = docText
        return result
    }

    @MainActor
    private func proposeEdits(_ args: [String: Any]) async throws -> Any {
        let doc = try document(args)
        guard let revision = args["revision"] as? Int else { throw ToolError("MISSING_REVISION") }
        guard revision == doc.revision else {
            throw ToolError("STALE_REVISION: document changed since your read; currentRevision=\(doc.revision) — re-read before proposing")
        }
        guard let author = args["author"] as? String, !author.isEmpty else { throw ToolError("MISSING_AUTHOR") }
        guard let edits = args["edits"] as? [[String: Any]], !edits.isEmpty else { throw ToolError("MISSING_EDITS") }
        guard edits.count <= 50 else { throw ToolError("TOO_MANY_EDITS: max 50 per call") }

        let editsJSON = String(data: try JSONSerialization.data(withJSONObject: edits), encoding: .utf8)!
        let authorJSON = String(data: try JSONSerialization.data(withJSONObject: author, options: [.fragmentsAllowed]), encoding: .utf8)!
        let raw = try await evaluateJS(doc,
            "JSON.stringify(window.Ashokan.applyAgentEdits(\(editsJSON), \(authorJSON)))") as? String ?? "{}"
        var result = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]

        // Let the async docChanged bump settle so the returned revision is current.
        try? await Task.sleep(nanoseconds: 250_000_000)
        result["newRevision"] = doc.revision
        result["note"] = "Edits applied as tracked changes for the user to accept or reject."
        return result
    }

    @MainActor
    private func reviewState(_ args: [String: Any]) async throws -> Any {
        let doc = try document(args)
        let raw = try await evaluateJS(doc, "JSON.stringify(window.Ashokan.getReviewState())") as? String ?? "{}"
        var result = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
        result["revision"] = doc.revision
        return result
    }

    @MainActor
    private func openDocument(_ args: [String: Any]) async throws -> Any {
        guard let path = args["path"] as? String else { throw ToolError("MISSING_PATH") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("FILE_NOT_FOUND: \(url.path)") }
        guard ["html", "htm", "md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw ToolError("UNSUPPORTED_TYPE: Ashokan opens .html/.htm/.md/.markdown")
        }
        let doc: Document = try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let document = document as? Document {
                    continuation.resume(returning: document)
                } else {
                    continuation.resume(throwing: ToolError("OPEN_FAILED: \(error?.localizedDescription ?? "unknown")"))
                }
            }
        }
        return summary(doc)
    }
}
