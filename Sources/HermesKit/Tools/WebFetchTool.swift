import Foundation
import FoundationModels

/// Plain HTTP GET, returned as readable text. Covers "call my server", Jellyfin/Home
/// Assistant style JSON APIs on the local network, and reading a web page. The model stays
/// on the phone; only this request goes out.
struct WebFetchTool: Tool {
    let name = "web_fetch"
    let description = "Fetch a URL with HTTP GET and return its text (HTML is stripped, JSON returned as-is)."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "Full http:// or https:// URL")
        var url: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let url = URL(string: arguments.url.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return "Error: provide a full http(s) URL."
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Hermes-iOS/0.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            var text = String(decoding: data.prefix(400_000), as: UTF8.self)
            if type.contains("html") { text = TextUtil.stripHTML(text) }
            await context.log(name, "\(url.host ?? "") \(status)")
            // ~2,500 chars ≈ 800 tokens: enough to answer from, small enough for 8K.
            return "HTTP \(status)\n" + TextUtil.truncate(text, to: 2_500)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
