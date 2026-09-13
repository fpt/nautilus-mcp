import XCTest

@testable import FoundationModelsKit

#if canImport(FoundationModels)

/// The on-device path keeps skill bodies here rather than in the session
/// instructions: two skills cost ~866 tokens inlined against ~101 for their
/// catalog, against a 4096-token window shared with the reply.
final class SkillStoreTests: XCTestCase {

    private func store(_ pairs: [(String, String, String)] = [
        ("desk-activity", "Connect the screen to a task board", "STEP ONE: call list_windows."),
        ("screen-analysis", "Look at what is on screen", "Capture, then OCR."),
    ]) -> SkillStore {
        let s = SkillStore()
        for (n, d, b) in pairs { s.add(name: n, description: d, body: b) }
        return s
    }

    func testEmptyStoreSaysSo() {
        XCTAssertTrue(SkillStore().isEmpty)
        XCTAssertTrue(SkillStore().list().contains("No skills registered"))
    }

    /// The catalog is what goes into the instructions — names and descriptions,
    /// never bodies. That split is the whole point.
    func testCatalogCarriesNamesAndDescriptionsbutNoBodies() {
        let lines = store().catalog()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.joined().contains("desk-activity"))
        XCTAssertTrue(lines.joined().contains("Connect the screen to a task board"))
        XCTAssertFalse(lines.joined().contains("STEP ONE"), "bodies must not be in the catalog")
    }

    func testCatalogIsSorted() {
        XCTAssertTrue(store().catalog()[0].contains("desk-activity"))
    }

    /// The reason the store exists: before this, the body was discarded and a
    /// skill was a name with nothing behind it.
    func testGetReturnsTheBody() {
        let out = store().get("desk-activity")
        XCTAssertTrue(out.contains("STEP ONE: call list_windows."), out)
        XCTAssertTrue(out.contains("desk-activity"), out)
    }

    func testGetIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(store().get("  Desk-Activity ").contains("STEP ONE"))
    }

    /// A miss names what is available. A model that guessed learns nothing from
    /// a bare "not found" and tends to guess again.
    func testMissNamesTheAlternatives() {
        let out = store().get("deploy")
        XCTAssertTrue(out.contains("No skill named 'deploy'"), out)
        XCTAssertTrue(out.contains("desk-activity"), "the miss should list what exists: \(out)")
    }

    func testMissOnAnEmptyStoreDoesNotPretendThereAreOptions() {
        let out = SkillStore().get("anything")
        XCTAssertTrue(out.contains("No skills are registered"), out)
    }

    /// A long skill must not spend the whole window in one call.
    func testBodyIsCapped() {
        let s = SkillStore()
        s.add(name: "huge", description: "d", body: String(repeating: "x", count: 50_000))
        let out = s.get("huge")
        XCTAssertLessThanOrEqual(out.count, 1500)
        XCTAssertTrue(out.contains("truncated"), out)
    }

    /// "Same name" must mean the same thing to `add` as it does to `get`.
    /// Matching exactly on add while looking up case-insensitively left two
    /// entries and returned the stale body.
    func testReplacementUsesTheSameKeyAsLookup() {
        let s = SkillStore()
        s.add(name: "desk-activity", description: "first", body: "old")
        s.add(name: "  Desk-Activity ", description: "second", body: "new")

        XCTAssertEqual(s.catalog().count, 1, "a differently-cased name is the same skill")
        let out = s.get("desk-activity")
        XCTAssertTrue(out.contains("new"), out)
        XCTAssertFalse(out.contains("old"), out)
    }

    /// Re-registering replaces, matching gallium's registry.
    func testAddingTheSameNameTwiceReplaces() {
        let s = SkillStore()
        s.add(name: "a", description: "first", body: "old")
        s.add(name: "a", description: "second", body: "new")
        XCTAssertEqual(s.catalog().count, 1)
        XCTAssertTrue(s.get("a").contains("new"))
        XCTAssertFalse(s.get("a").contains("old"))
    }
}

#endif
