import Foundation
import XCTest
import RoachNetCore

/// "Download recommended" on a Study Shelf card.
final class EducationTierTests: XCTestCase {
    private func category(_ json: String) throws -> EducationCategory {
        try JSONDecoder().decode(EducationCategory.self, from: Data(json.utf8))
    }

    func testRecommendedTierIsUsedWhenItHasBooks() throws {
        let shelf = try category(#"""
        {"slug": "medicine", "name": "Medicine", "tiers": [
          {"name": "Essential", "slug": "medicine-essential", "recommended": true, "resources": [{"id": "a", "title": "A"}]},
          {"name": "Standard", "slug": "medicine-standard", "resources": [{"id": "b", "title": "B"}]}]}
        """#)
        XCTAssertEqual(shelf.tierToRecommend?.slug, "medicine-essential")
    }

    func testAnEmptyRecommendedTierFallsBackToOneThatCanDownload() throws {
        // The runtime drops books Kiwix no longer serves, which can leave the recommended tier empty.
        let shelf = try category(#"""
        {"slug": "math-logic", "name": "Math", "tiers": [
          {"name": "Essential", "slug": "math-logic-essential", "recommended": true, "resources": []},
          {"name": "Standard", "slug": "math-logic-standard", "resources": [{"id": "math", "title": "Math Q&A"}]}]}
        """#)
        XCTAssertEqual(shelf.tierToRecommend?.slug, "math-logic-standard")
        let empty = try category(#"{"slug": "x", "name": "X", "tiers": [{"name": "E", "slug": "x-e", "recommended": true, "resources": []}]}"#)
        XCTAssertNil(empty.tierToRecommend, "nothing to queue means no download button target")
    }
}
