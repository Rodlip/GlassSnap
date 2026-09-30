import XCTest
@testable import SnapGeometry

final class WindowSelectionTests: XCTestCase {
    func testQuickReleaseCommitsNextWindowAfterDiscovery() {
        var selection = WindowSelection(advance: 1)
        XCTAssertFalse(selection.requestCommit())
        XCTAssertTrue(selection.loaded(count: 4))
        XCTAssertEqual(selection.index, 1)
    }
    func testRepeatedTabsDuringDiscoveryAreNotLost() {
        var selection = WindowSelection(advance: 1)
        selection.move(by: 1)
        selection.move(by: 1)
        XCTAssertFalse(selection.loaded(count: 5))
        XCTAssertEqual(selection.index, 3)
        XCTAssertTrue(selection.requestCommit())
    }
    func testReverseAndForwardWrap() {
        var selection = WindowSelection(advance: -1)
        _ = selection.loaded(count: 3)
        XCTAssertEqual(selection.index, 2)
        selection.move(by: 1)
        XCTAssertEqual(selection.index, 0)
        selection.move(by: -1)
        XCTAssertEqual(selection.index, 2)
    }
    func testEmptyCatalogNeverCommits() {
        var selection = WindowSelection(advance: 1)
        XCTAssertFalse(selection.requestCommit())
        XCTAssertFalse(selection.loaded(count: 0))
        selection.move(by: -1)
        XCTAssertEqual(selection.index, 0)
        XCTAssertFalse(selection.requestCommit())
    }
    func testClosingAppClampsSelectionWithoutSkippingRemainingWindows() {
        var selection = WindowSelection(advance: -1)
        _ = selection.loaded(count: 10)
        selection.updateCount(3)
        XCTAssertEqual(selection.index, 2)
        selection.move(by: 1)
        XCTAssertEqual(selection.index, 0)
        selection.updateCount(0)
        XCTAssertFalse(selection.requestCommit())
    }
}
