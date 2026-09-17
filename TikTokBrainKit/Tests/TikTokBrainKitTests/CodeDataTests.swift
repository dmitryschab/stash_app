import Foundation
import XCTest
@testable import TikTokBrainKit

final class CodeDataTests: XCTestCase {
    private func decode(_ json: String) throws -> CodeData {
        try JSONDecoder().decode(CodeData.self, from: json.data(using: .utf8)!)
    }

    func testLegacyPayloadDecodesWithNoKindAndNoItems() throws {
        let code = try decode(#"{"summary":"s","links":["https://swift.org"],"techTags":["swift"]}"#)

        XCTAssertNil(code.kind)
        XCTAssertEqual(code.items, [])
        XCTAssertEqual(code.techTags, ["swift"])
    }

    func testDecodeReadsKindAndCleansItems() throws {
        let code = try decode(#"""
        {"summary":"","links":[],"techTags":[],"kind":"checklist","items":[
          {"text":"  add rate limiting ","detail":""},
          {"text":"   ","detail":"blank"},
          {"text":"Add Rate Limiting","detail":"duplicate"},
          {"text":"set API limits","detail":" per key "},
          {"text":"add error handling"}
        ]}
        """#)

        XCTAssertEqual(code.kind, .checklist)
        XCTAssertEqual(code.items, [
            CodeItem(text: "add rate limiting", detail: ""),
            CodeItem(text: "set API limits", detail: "per key"),
            CodeItem(text: "add error handling", detail: ""),
        ])
    }

    func testUnknownKindDecodesAsNilAndKeepsItems() throws {
        let code = try decode(#"{"summary":"","links":[],"techTags":[],"kind":"rant","items":[{"text":"one","detail":""}]}"#)

        XCTAssertNil(code.kind)
        XCTAssertEqual(code.items.map(\.text), ["one"])
    }

    func testItemsAreCappedAtMaxPerVideo() throws {
        let entries = (0..<40).map { #"{"text":"item \#($0)","detail":""}"# }.joined(separator: ",")
        let code = try decode(#"{"summary":"","links":[],"techTags":[],"kind":"howto","items":[\#(entries)]}"#)

        XCTAssertEqual(code.items.count, CodeData.maxItems)
        XCTAssertEqual(code.items.first?.text, "item 0")
    }

    func testCodeItemsSurviveAnalysisRoundTrip() throws {
        let json = #"{"category":"coding","title":"t","summary":"","topics":[],"code":{"summary":"","links":[],"techTags":[],"kind":"tools","items":[{"text":"Scrapling","detail":"adaptive scraping"}]}}"#
        let analysis = try JSONDecoder().decode(Analysis.self, from: json.data(using: .utf8)!)
        let stored = try JSONEncoder().encode(analysis.code)
        let code = try JSONDecoder().decode(CodeData.self, from: stored)

        XCTAssertEqual(code.kind, .tools)
        XCTAssertEqual(code.items, [CodeItem(text: "Scrapling", detail: "adaptive scraping")])
    }

    func testChecklistStatePersistsPerItemAcrossReanalysis() throws {
        let video = Video(videoID: "7000000000000000001",
                          url: URL(string: "https://www.tiktok.com/@example/video/7000000000000000001")!,
                          bookmarkedAt: Date(timeIntervalSince1970: 100))
        let item = CodeItem(text: "Add rate limiting", detail: "")
        XCTAssertFalse(video.isChecked(item))

        video.setChecked(true, for: item)
        XCTAssertTrue(video.isChecked(item))
        // A re-run can change spacing, case and the detail; the item is still the same item.
        XCTAssertTrue(video.isChecked(CodeItem(text: "  add RATE\tlimiting ", detail: "changed")))
        XCTAssertFalse(video.isChecked(CodeItem(text: "set API limits", detail: "")))

        video.setChecked(false, for: item)
        XCTAssertFalse(video.isChecked(item))
        XCTAssertNil(video.codeChecksJSON)
    }
}

final class CodeDataLabelTests: XCTestCase {
    private func code(_ kind: CodeData.Kind?, _ count: Int) throws -> CodeData {
        let items = (0..<count).map { #"{"text":"item \#($0)","detail":""}"# }.joined(separator: ",")
        let kindField = kind.map { #","kind":"\#($0.rawValue)""# } ?? ""
        return try JSONDecoder().decode(CodeData.self, from: #"{"summary":"","links":[],"techTags":[]\#(kindField),"items":[\#(items)]}"#.data(using: .utf8)!)
    }

    func testShelfLabelNamesTheShapeAndCount() throws {
        XCTAssertEqual(try code(.checklist, 20).shelfLabel, "checklist · 20")
        XCTAssertEqual(try code(.tools, 6).shelfLabel, "6 tools")
        XCTAssertEqual(try code(.tools, 1).shelfLabel, "1 tool")
        XCTAssertEqual(try code(.howto, 4).shelfLabel, "4 steps")
        XCTAssertEqual(try code(.explainer, 5).shelfLabel, "5 takeaways")
        XCTAssertEqual(try code(nil, 3).shelfLabel, "3 takeaways")
        XCTAssertNil(try code(.checklist, 0).shelfLabel)
    }

    func testSectionHeadlineCountsChecklistProgress() throws {
        XCTAssertEqual(try code(.checklist, 20).headline(checked: 7), "Checklist · 7 of 20")
        XCTAssertEqual(try code(.howto, 4).headline(checked: 0), "Steps")
        XCTAssertEqual(try code(.tools, 6).headline(checked: 0), "6 tools")
        XCTAssertEqual(try code(.explainer, 5).headline(checked: 0), "Takeaways")
    }
}
