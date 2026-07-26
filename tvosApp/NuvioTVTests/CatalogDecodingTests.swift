import XCTest
@testable import NuvioTV

/// Regression cover for the add-on catalog decoder. A Stremio catalog page is
/// decoded as one array of metas, so a single entry with an off-spec field
/// shape used to throw and drop the whole row from Home.
final class CatalogDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testAcceptsSpecCompliantStringArray() throws {
        let people = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#"["Lana Wachowski","Lilly Wachowski"]"#.utf8)
        )
        XCTAssertEqual(people.values, ["Lana Wachowski", "Lilly Wachowski"])
    }

    /// Add-ons that already worked must be unaffected by this type. Entries
    /// pass through verbatim — no trimming, no dropping — because
    /// CastCrewSection identifies rows by the name string, so normalising
    /// here could merge two rows that render distinctly today.
    func testArrayEntriesArePassedThroughVerbatim() throws {
        let people = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#"["Nolan","Nolan ",""," Martin Luther King, Jr."]"#.utf8)
        )
        XCTAssertEqual(
            people.values,
            ["Nolan", "Nolan ", "", " Martin Luther King, Jr."]
        )
    }

    func testAcceptsSingleScalarString() throws {
        let people = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#""Christopher Nolan""#.utf8)
        )
        XCTAssertEqual(people.values, ["Christopher Nolan"])
    }

    /// AIO Metadata joins the list into one string; splitting it back apart
    /// keeps the cast row from rendering as a single run-on entry.
    func testSplitsCommaJoinedScalarAndTrimsPadding() throws {
        let people = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#""Lana Wachowski,  Lilly Wachowski , Keanu Reeves""#.utf8)
        )
        XCTAssertEqual(
            people.values,
            ["Lana Wachowski", "Lilly Wachowski", "Keanu Reeves"]
        )
    }

    func testDropsEmptyAndUnsupportedShapesWithoutThrowing() throws {
        let blank = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#""   ""#.utf8)
        )
        XCTAssertEqual(blank.values, [])

        // An object or number must degrade to "no people", never to a throw
        // that would cost the caller the entire catalog page.
        let unsupported = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#"{"name":"Christopher Nolan"}"#.utf8)
        )
        XCTAssertEqual(unsupported.values, [])
    }

    /// The actual bug: one off-spec `director` inside a catalog page.
    func testCatalogPageSurvivesOffSpecPeopleField() throws {
        let json = Data("""
        {"metas":[
          {"id":"tt0133093","type":"movie","name":"The Matrix",
           "director":["Lana Wachowski"]},
          {"id":"tt1375666","type":"movie","name":"Inception",
           "director":"Christopher Nolan","cast":"Leonardo DiCaprio, Elliot Page"}
        ]}
        """.utf8)

        struct Page: Decodable {
            struct Entry: Decodable {
                let name: String
                let director: FlexibleStringArray?
                let cast: FlexibleStringArray?
            }
            let metas: [Entry]
        }

        let page = try decoder.decode(Page.self, from: json)
        XCTAssertEqual(page.metas.count, 2, "off-spec entry must not drop the page")
        XCTAssertEqual(page.metas[0].director?.values, ["Lana Wachowski"])
        XCTAssertEqual(page.metas[1].director?.values, ["Christopher Nolan"])
        XCTAssertEqual(
            page.metas[1].cast?.values,
            ["Leonardo DiCaprio", "Elliot Page"]
        )
    }
}
