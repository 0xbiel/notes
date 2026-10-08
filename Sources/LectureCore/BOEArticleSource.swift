import Foundation

public struct BOEArticleSource: Sendable {
    public init() {}
    public func fetch(_ query: NotebookArticleQuery) async throws -> String {
        guard query.lawID.range(of: "^BOE-A-[0-9]{4}-[0-9]+$", options: .regularExpression) != nil,
              !query.article.isEmpty, query.article.count < 40, query.lawName.count >= 4 else { throw MediaError.invalid("Indica la ley o su enlace BOE para resolver el artículo.") }
        let base = "https://www.boe.es/datosabiertos/api/legislacion-consolidada/id/" + query.lawID
        let metadata = try await load(base + "/metadatos")
        let index = try await load(base + "/texto/indice")
        let block = try Self.blockID(index, article: query.article)
        guard block.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw MediaError.invalid("Identificador de artículo inválido.") }
        let data = try await load(base + "/texto/bloque/" + block)
        return try Self.render(metadata: metadata, block: data, query: query, blockID: block)
    }
    private func load(_ address: String) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == "www.boe.es", data.count <= 8_000_000 else { throw MediaError.invalid("No se pudo verificar el artículo en BOE. No se ha insertado texto legal.") }
        return data
    }
    private static func xml(_ data: Data) throws -> XMLDocument {
        guard data.count <= 8_000_000 else { throw MediaError.invalid("Respuesta BOE demasiado grande.") }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard try document.nodes(forXPath: "/response/status/code").first?.stringValue == "200" else { throw MediaError.invalid("BOE no encontró la norma o el artículo.") }
        return document
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    public static func blockID(_ data: Data, article: String) throws -> String {
        let doc = try xml(data)
        let target = normalized("Artículo " + article)
        let matches = try doc.nodes(forXPath: "/response/data/bloque").compactMap { $0 as? XMLElement }.filter {
            normalized($0.elements(forName: "titulo").first?.stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")) == target
        }
        guard matches.count == 1, let id = matches[0].elements(forName: "id").first?.stringValue else { throw MediaError.invalid("Artículo ausente o ambiguo en la norma. Indica el artículo exacto.") }
        return id
    }
    public static func render(metadata: Data, block: Data, query: NotebookArticleQuery, blockID: String, today: Date = Date()) throws -> String {
        let meta = try xml(metadata), doc = try xml(block)
        guard let title = try meta.nodes(forXPath: "/response/data/metadatos/titulo").first?.stringValue,
              normalized(title).contains(normalized(query.lawName)),
              try meta.nodes(forXPath: "/response/data/metadatos/identificador").first?.stringValue == query.lawID else { throw MediaError.invalid("La norma BOE no coincide con la ley solicitada. Confirma la ley.") }
        guard let element = try doc.nodes(forXPath: "/response/data/bloque").first as? XMLElement,
              element.attribute(forName: "id")?.stringValue == blockID,
              normalized(element.attribute(forName: "titulo")?.stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")) == normalized("Artículo " + query.article) else { throw MediaError.invalid("El artículo recibido no coincide con la referencia.") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        let date: Date
        if query.date.isEmpty { date = today }
        else {
            guard let parsed = formatter.date(from: query.date), formatter.string(from: parsed) == query.date, parsed <= today else { throw MediaError.invalid("Fecha histórica inválida.") }
            date = parsed
        }
        formatter.dateFormat = "yyyyMMdd"
        let cutoff = formatter.string(from: date)
        let versions = element.elements(forName: "version").filter {
            let published = $0.attribute(forName: "fecha_publicacion")?.stringValue ?? ""
            let effective = $0.attribute(forName: "fecha_vigencia")?.stringValue ?? published
            return !published.isEmpty && !effective.isEmpty && published <= cutoff && effective <= cutoff
        }.sorted {
            ($0.attribute(forName: "fecha_vigencia")?.stringValue ?? $0.attribute(forName: "fecha_publicacion")?.stringValue ?? "") < ($1.attribute(forName: "fecha_vigencia")?.stringValue ?? $1.attribute(forName: "fecha_publicacion")?.stringValue ?? "")
        }
        guard let version = versions.last else { throw MediaError.invalid("El artículo no tiene una versión verificable en esa fecha.") }
        let paragraphs = (version.children ?? []).compactMap { node -> String? in
            guard let element = node as? XMLElement, ["p", "table", "ul", "ol"].contains(element.name ?? ""), element.attribute(forName: "class")?.stringValue != "nota_pie" else { return nil }
            return element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { throw MediaError.invalid("El artículo no contiene texto verificable.") }
        let versionDate = version.attribute(forName: "fecha_vigencia")?.stringValue ?? version.attribute(forName: "fecha_publicacion")?.stringValue ?? ""
        let readable = formatter.date(from: versionDate).map { date -> String in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
        } ?? versionDate
        let url = "https://www.boe.es/buscar/act.php?id=\(query.lawID)&p=\(cutoff)#\(blockID)"
        return "### \(title) · Artículo \(query.article)\n\n" + paragraphs.map { "> " + $0.replacingOccurrences(of: "\n", with: "\n> ") }.joined(separator: "\n>\n") + "\n\n[Fuente: BOE](\(url)) · Versión vigente desde \(readable) · Consulta \(cutoff)."
    }
}
