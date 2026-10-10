import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin
import CryptoKit

public struct NotebookWebAction: Codable, Equatable, Sendable {
    public var kind: String
    public var query: String
    public var url: String
    /// Where a downloaded file goes inside the notebook.
    public var path: String?
    public init(kind: String, query: String = "", url: String = "", path: String? = nil) { self.kind = kind; self.query = query; self.url = url; self.path = path }
}
public struct NotebookWebResult: Codable, Sendable {
    public var action: NotebookWebAction
    public var source: String
    public var text: String
    public var imageURLs: [String] = []
    public var localImagePath: String? = nil
    public var localFilePath: String? = nil
    public var error: String? = nil
    public init(action: NotebookWebAction, source: String, text: String, imageURLs: [String] = [], localImagePath: String? = nil, localFilePath: String? = nil, error: String? = nil) {
        self.action = action; self.source = source; self.text = text; self.imageURLs = imageURLs; self.localImagePath = localImagePath; self.localFilePath = localFilePath; self.error = error
    }
}

/// Public-web reads use an ephemeral session: no account cookies, local files or scripts.
public struct NotebookWebClient: Sendable {
    private let fixtureFetch: (@Sendable (URL) async throws -> (Data, HTTPURLResponse))?
    public init() { fixtureFetch = nil }
    init(fetch: @escaping @Sendable (URL) async throws -> (Data, HTTPURLResponse)) { fixtureFetch = fetch }
    public static func validateURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host != "localhost", host != "0.0.0.0", !host.contains(":"),
              !host.hasPrefix("127."), !host.hasPrefix("10."), !host.hasPrefix("192.168."),
              !host.hasPrefix("169.254."), !host.hasPrefix("0."),
              !(host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? -1)) else {
            throw MediaError.invalid("Only public HTTPS web addresses are supported.")
        }
        return url
    }
    public func execute(_ action: NotebookWebAction, workspaceRoot: URL, originalRoot: URL, notebook: Notebook) async throws -> NotebookWebResult {
        let workspace = try SafeWorkspace(root: workspaceRoot, originalRoot: originalRoot)
        switch action.kind {
        case "search":
            guard !action.query.isEmpty, action.query.count <= 500 else { throw MediaError.invalid("Invalid web search query.") }
            var url = URLComponents(string: "https://www.bing.com/search")!
            url.queryItems = [.init(name: "q", value: action.query), .init(name: "format", value: "rss")]
            let (data, _) = try await fetch(url.url!.absoluteString, limit: 2_000_000)
            let parser = WebSearchFeed(); let xml = XMLParser(data: data); xml.delegate = parser
            guard xml.parse(), !parser.results.isEmpty else { throw MediaError.invalid("Web search returned no readable results. Try a more specific query.") }
            let text = parser.results.prefix(8).joined(separator: "\n\n")
            return .init(action: action, source: url.url!.absoluteString, text: text)
        case "read":
            let (data, response) = try await fetch(action.url, limit: 2_000_000)
            guard response.mimeType?.contains("text") == true || response.mimeType?.contains("html") == true,
                  let html = String(data: data, encoding: .utf8) else { throw MediaError.invalid("This page is not readable text. Use downloadImage for an image URL.") }
            return .init(action: action, source: response.url?.absoluteString ?? action.url,
                         text: Self.pageText(html), imageURLs: Self.imageURLs(html, base: response.url!))
        case "downloadImage":
            let (data, response) = try await fetch(action.url, limit: 20_000_000)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source), let uti = UTType(type as String),
                  [UTType.png, .jpeg, .gif, .webP].contains(where: { uti.conforms(to: $0) }),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 12_000, height <= 12_000, width * height <= 40_000_000,
                  CGImageSourceGetCount(source) <= 500, width * height * CGImageSourceGetCount(source) <= 100_000_000 else {
                throw MediaError.invalid("The download is not a supported PNG, JPEG, GIF or WebP image.")
            }
            try Task.checkCancellation()
            let ext = uti.preferredFilenameExtension ?? "png"
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let path = (notebook.rootPrefix.isEmpty ? "" : notebook.rootPrefix + "/") + ".palladium-images/" + digest + "." + ext
            if !FileManager.default.fileExists(atPath: try workspace.fileURL(path).path) { try workspace.createAsset(path, data: data) }
            return .init(action: action, source: response.url?.absoluteString ?? action.url,
                         text: "Downloaded locally. Use this file in Markdown, with a path relative to the note. Preserve a source link.", localImagePath: path)
        default: throw MediaError.invalid("Unknown web action.")
        }
    }
    public struct Download: Sendable {
        public var data: Data
        public var source: String
        /// The server's name for the file, with an extension when one can be told.
        public var name: String
    }
    /// Fetches a document such as a PDF. The caller stores it through the notebook library.
    public func download(_ action: NotebookWebAction) async throws -> Download {
        let (data, response) = try await fetch(action.url, limit: .max)
        guard !data.isEmpty else { throw MediaError.invalid("The download is empty.") }
        let mime = response.mimeType?.lowercased() ?? ""
        guard !mime.contains("html") else { throw MediaError.invalid("This address is a web page, not a file. Use read for pages, or find the direct link to the file.") }
        var name = response.suggestedFilename ?? response.url?.lastPathComponent ?? "download"
        if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = data.starts(with: Data("%PDF".utf8)) ? "pdf" : UTType(mimeType: mime)?.preferredFilenameExtension { name += "." + ext }
        return .init(data: data, source: response.url?.absoluteString ?? action.url, name: name)
    }
    /// The notebook path for a download: the requested one, kept inside the notebook and given the file's extension.
    public static func destination(for action: NotebookWebAction, name: String, notebook: Notebook) throws -> String {
        var path = (action.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        if path.isEmpty { path = name }
        if !notebook.rootPrefix.isEmpty, path != notebook.rootPrefix, !path.hasPrefix(notebook.rootPrefix + "/") { path = notebook.rootPrefix + "/" + path }
        let ext = URL(fileURLWithPath: name).pathExtension
        if URL(fileURLWithPath: path).pathExtension.isEmpty, !ext.isEmpty { path += "." + ext }
        let parts = path.components(separatedBy: "/"), type = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard path.count <= 300, !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") }), !type.isEmpty, path != notebook.rootPrefix else { throw MediaError.invalid("Invalid destination for the download. Give a path inside the notebook with a file name.") }
        guard type != "md" else { throw MediaError.invalid("Create Markdown notes through edits, not downloads.") }
        let kind = UTType(filenameExtension: type)
        guard kind?.conforms(to: .audio) != true, kind?.conforms(to: .movie) != true, kind?.conforms(to: .executable) != true, !["app", "command", "sh", "pkg", "dmg"].contains(type) else { throw MediaError.invalid("Audio, video and programs are not downloaded into notebooks.") }
        return path
    }
    private func fetch(_ raw: String, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let url = try Self.validateURL(raw)
        if let fixtureFetch {
            let result = try await fixtureFetch(url)
            guard result.0.count <= limit, (200..<300).contains(result.1.statusCode) else { throw MediaError.invalid("Web content exceeds the download limit or failed.") }
            return result
        }
        try Self.validateHost(url)
        let delegate = PublicWebRedirects()
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = limit > 20_000_000 ? 3_600 : 40
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("Palladium/0.3", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= Int64(limit) else { throw MediaError.invalid("Web request failed or exceeds the download limit.") }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw MediaError.invalid("Web content exceeds the download limit.") }
            data.append(byte)
        }
        return (data, http)
    }
    static func validateHost(_ url: URL) throws {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(url.host!, nil, &hints, &addresses) == 0, let first = addresses else { throw MediaError.invalid("Web host could not be resolved.") }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current {
            let value = entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let a = value >> 24, b = (value >> 16) & 255
            guard a != 0, a != 10, a != 127, a < 224, !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)), !(a == 192 && b == 168), !(a == 100 && (64...127).contains(b)) else { throw MediaError.invalid("Private network addresses are not supported.") }
            current = entry.pointee.ai_next
        }
    }
    static func pageText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style|noscript)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        return String(unescape(text).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(16_000))
    }
    static func imageURLs(_ html: String, base: URL) -> [String] {
        let pattern = #"(?is)(?:content|src)\s*=\s*["']([^"']+\.(?:gif|png|jpe?g|webp)(?:\?[^"']*)?)["']|https?:\\?/\\?/[^\s"'<>]+?\.(?:gif|png|jpe?g|webp)(?:\?[^\s"'<>]*)?"#
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: html, range: NSRange(location: 0, length: html.utf16.count)) ?? []
        var urls: [String] = []
        for match in matches {
            let range = match.range(at: 1).location == NSNotFound ? match.range : match.range(at: 1)
            let raw = unescape((html as NSString).substring(with: range)).replacingOccurrences(of: "\\/", with: "/")
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL, (try? validateURL(url.absoluteString)) != nil, !urls.contains(url.absoluteString) else { continue }
            urls.append(url.absoluteString); if urls.count == 20 { break }
        }
        return urls
    }
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}
private final class PublicWebRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do { let url = try NotebookWebClient.validateURL(request.url?.absoluteString ?? ""); try NotebookWebClient.validateHost(url); completionHandler(request) } catch { completionHandler(nil) }
    }
}
private final class WebSearchFeed: NSObject, XMLParserDelegate {
    var results: [String] = []; private var inside = false; private var tag = ""; private var title = ""; private var link = ""; private var snippet = ""
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        tag = element
        if element == "item" { inside = true; title = ""; link = ""; snippet = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inside else { return }
        switch tag { case "title": title += string; case "link": link += string; case "description": snippet += string; default: break }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "item" { if (try? NotebookWebClient.validateURL(link)) != nil { results.append(title + "\n" + link + "\n" + snippet) }; inside = false }
        tag = ""
    }
}
