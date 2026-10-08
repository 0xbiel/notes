import XCTest
@testable import LectureCore

final class BOEArticleTests: XCTestCase {
    private func wrap(_ content: String) -> Data { Data("<response><status><code>200</code></status><data>\(content)</data></response>".utf8) }
    private var metadata: Data { wrap("<metadatos><identificador>BOE-A-2015-11430</identificador><titulo>Ley del Estatuto de los Trabajadores</titulo></metadatos>") }
    private var block: Data { wrap("""
    <bloque id="a13" titulo="Artículo 13">
    <version fecha_publicacion="20151024" fecha_vigencia="20151113"><p>Artículo 13.</p><p>Texto antiguo.</p></version>
    <version fecha_publicacion="20210710" fecha_vigencia="20210711"><p>Artículo 13.</p><p>Texto <b>actual</b> y exacto.</p><blockquote><p class="nota_pie">Nota editorial que no es el artículo.</p></blockquote></version>
    <version fecha_publicacion="20900101" fecha_vigencia="20910101"><p>Futuro.</p></version>
    </bloque>
    """) }
    func testExactArticleIndexAndMissingArticle() throws {
        let data = wrap("<bloque><id>a13</id><titulo>Artículo 13</titulo></bloque><bloque><id>a130</id><titulo>Artículo 130</titulo></bloque>")
        XCTAssertEqual(try BOEArticleSource.blockID(data, article: "13"), "a13")
        XCTAssertThrowsError(try BOEArticleSource.blockID(data, article: "14"))
    }
    func testLatestAndHistoricalTextKeepOfficialContentAndCitation() throws {
        let current = try BOEArticleSource.render(metadata: metadata, block: block, query: .init(lawID: "BOE-A-2015-11430", lawName: "Estatuto de los Trabajadores", article: "13"), blockID: "a13")
        XCTAssertTrue(current.contains("Texto actual y exacto.")); XCTAssertFalse(current.contains("Nota editorial")); XCTAssertFalse(current.contains("Futuro")); XCTAssertTrue(current.contains("2021-07-11")); XCTAssertTrue(current.contains("https://www.boe.es/"))
        let old = try BOEArticleSource.render(metadata: metadata, block: block, query: .init(lawID: "BOE-A-2015-11430", lawName: "Estatuto", article: "13", date: "2016-01-01"), blockID: "a13")
        XCTAssertTrue(old.contains("Texto antiguo.")); XCTAssertFalse(old.contains("Texto actual"))
    }
    func testMismatchedLawArticleInvalidDateAndNoHistoricalVersionFail() {
        for query in [NotebookArticleQuery(lawID: "BOE-A-2015-11430", lawName: "Código Civil", article: "13"), .init(lawID: "BOE-A-2015-11430", lawName: "Estatuto", article: "130"), .init(lawID: "BOE-A-2015-11430", lawName: "Estatuto", article: "13", date: "2010-01-01"), .init(lawID: "BOE-A-2015-11430", lawName: "Estatuto", article: "13", date: "2020-02-31")] {
            XCTAssertThrowsError(try BOEArticleSource.render(metadata: metadata, block: block, query: query, blockID: "a13"))
        }
        XCTAssertThrowsError(try BOEArticleSource.blockID(Data("<response><status><code>404</code></status><data/></response>".utf8), article: "13"))
    }
}
