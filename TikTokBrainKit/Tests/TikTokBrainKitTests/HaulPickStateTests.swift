import Foundation
import SwiftData
import XCTest
@testable import TikTokBrainKit

final class HaulPickStateTests: XCTestCase {
    private func video(_ id: String = "7000000000000000001") -> Video {
        Video(videoID: id, url: URL(string: "https://www.tiktok.com/@example/video/\(id)")!,
              bookmarkedAt: Date(timeIntervalSince1970: 100))
    }

    func testUnmarkedPickCanBeWantedBoughtAndClearedWithoutChangingAnotherPick() {
        let video = video()
        let shoes = BuyPick(name: "Nike Vomero 5")
        let keyboard = BuyPick(name: "Keychron K3 Pro")
        XCTAssertNil(video.haulState(for: shoes))

        video.setHaulState(.want, for: shoes)
        video.setHaulState(.bought, for: keyboard)
        XCTAssertEqual(video.haulState(for: shoes), .want)
        video.setHaulState(.bought, for: shoes)
        XCTAssertEqual(video.haulState(for: shoes), .bought)

        video.setHaulState(nil, for: shoes)
        XCTAssertNil(video.haulState(for: shoes))
        XCTAssertEqual(video.haulState(for: keyboard), .bought)
    }

    func testReorderedAndRefinedPicksKeepTheStateOfTheirProduct() throws {
        let video = video()
        let shoes = BuyPick(name: "Nike Vomero 5", kind: "shoes", price: "€100")
        let keyboard = BuyPick(name: "Keychron K3 Pro", kind: "keyboard")
        video.buysJSON = try JSONEncoder().encode([shoes, keyboard])
        video.setHaulState(.want, for: shoes)
        video.setHaulState(.bought, for: keyboard)

        // A richer analysis can reorder results, refine the category, and discover a link.
        let refreshedShoes = BuyPick(name: "  NIKE\tVOMERO\n5  ", kind: "sneakers", price: "€120",
                                     link: URL(string: "https://example.com/shoes"))
        video.buysJSON = try JSONEncoder().encode([keyboard, refreshedShoes])
        let refreshed = try JSONDecoder().decode([BuyPick].self, from: XCTUnwrap(video.buysJSON))
        XCTAssertEqual(video.haulState(for: refreshed[0]), .bought)
        XCTAssertEqual(video.haulState(for: refreshed[1]), .want)
        XCTAssertNil(video.haulState(for: BuyPick(name: "Nike Vomero 6")))
    }

    func testSameProductInAnotherVideoDoesNotInheritState() {
        let first = video()
        let second = video("7000000000000000002")
        let pick = BuyPick(name: "Nike Vomero 5")
        first.setHaulState(.want, for: pick)
        XCTAssertNil(second.haulState(for: pick))
    }

    func testStateSurvivesStoreReloadAndIsRemovedWithItsVideo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("haul.store"))
        let pick = BuyPick(name: "Nike Vomero 5")

        try autoreleasepool {
            let container = try ModelContainer(for: Video.self, configurations: configuration)
            let context = ModelContext(container)
            let saved = video()
            context.insert(saved)
            saved.setHaulState(.bought, for: pick)
            try context.save()
        }

        try autoreleasepool {
            let container = try ModelContainer(for: Video.self, configurations: configuration)
            let context = ModelContext(container)
            let saved = try XCTUnwrap(context.fetch(FetchDescriptor<Video>()).first)
            XCTAssertEqual(saved.haulState(for: pick), .bought)
            // The app uses this same deletion for account deletion and account switching.
            try context.delete(model: Video.self)
            try context.save()
        }

        try autoreleasepool {
            let container = try ModelContainer(for: Video.self, configurations: configuration)
            let context = ModelContext(container)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Video>()).isEmpty)
            let savedAgain = video()
            context.insert(savedAgain)
            try context.save()
            XCTAssertNil(savedAgain.haulState(for: pick))
        }
    }
}
