import Cocoa

/// The embedded protocol that teaches AI agents (Claude Code, Codex, a local
/// model) to make tracked changes instead of rewriting text. Lives in an HTML
/// comment: invisible in every browser, read by any agent that opens the file.
enum AgentProtocol {
    static func instructionsComment(task: String) -> String {
        let taskLine = task.isEmpty ? "Review for clarity, correctness, and tone." : task
        return """
        <!-- ashokan-agent-instructions
        INSTRUCTIONS FOR AI AGENTS (Claude Code, Codex, etc.) EDITING THIS FILE

        When asked to review or revise this document, do NOT rewrite text in
        place. Record every change as a tracked suggestion using standard HTML:

        1. Replace text:  <del data-ashokan-author="YOUR-NAME">old</del><ins data-ashokan-author="YOUR-NAME">new</ins>
        2. Insert text:   <ins data-ashokan-author="YOUR-NAME">added text</ins>
        3. Delete text:   <del data-ashokan-author="YOUR-NAME">removed text</del>
        4. Comment:       <mark title="your comment" data-ashokan-author="YOUR-NAME">the text commented on</mark>

        Rules:
        - YOUR-NAME is your agent/model name (e.g. "Claude Code").
        - Keep every other byte of markup, including this <head>, exactly as-is.
        - Do not nest <ins> inside <del>. Keep suggestions small and local.
        - The document owner will accept or reject each suggestion in Ashokan.

        TASK: \(taskLine)
        -->
        """
    }

    static let ollamaSystemPrompt = """
    You are reviewing a document. Respond ONLY with a JSON array of suggestion \
    objects — no prose, no markdown, no code fences.
    Each object has these fields:
      "quote": EXACT contiguous text copied verbatim from the document \
    (10-150 characters, unique within its paragraph). Required.
      "replacement": improved text to substitute for the quote. Omit when only commenting.
      "comment": a short note explaining the change or raising a question. Optional.
    Make 3-8 focused suggestions. Never include a suggestion that changes nothing.
    """
}

/// Minimal client for a local Ollama server. Local-only by design: documents
/// never leave the machine.
final class OllamaClient {
    static let shared = OllamaClient()
    var baseURL = URL(string: "http://localhost:11434")!

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    func listModels(_ completion: @escaping ([String]) -> Void) {
        let task = session.dataTask(with: baseURL.appendingPathComponent("api/tags")) { data, _, _ in
            var names: [String] = []
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                names = models.compactMap { $0["name"] as? String }
            }
            DispatchQueue.main.async { completion(names) }
        }
        task.resume()
    }

    func chat(model: String, system: String, user: String,
              completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["temperature": 0.2],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = session.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = json["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    completion(.failure(NSError(domain: "Ashokan", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Unexpected response from Ollama.",
                    ])))
                    return
                }
                completion(.success(content))
            }
        }
        task.resume()
    }

    /// Extracts the first JSON array from model output that may include
    /// thinking text or code fences despite instructions.
    static func extractSuggestions(from content: String) -> [[String: Any]]? {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"), start < end else { return nil }
        let slice = String(content[start...end])
        guard let data = slice.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return array
    }
}
