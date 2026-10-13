import XCTest
@testable import SnapGeometry

final class ReleaseVersionTests: XCTestCase {
    func testTagsCompareNumerically() {
        XCTAssertLessThan(ReleaseVersion("0.9.0")!, ReleaseVersion("v0.10.0")!)
        XCTAssertLessThan(ReleaseVersion("0.3")!, ReleaseVersion("0.3.1")!)
        XCTAssertEqual(ReleaseVersion("v1.2")!, ReleaseVersion("1.2.0")!)
        XCTAssertFalse(ReleaseVersion("1.2.0")! < ReleaseVersion("1.2")!)
    }
    func testMalformedTagsAreRejected() {
        XCTAssertNil(ReleaseVersion(""))
        XCTAssertNil(ReleaseVersion("v1.x"))
        XCTAssertNil(ReleaseVersion("1..2"))
        XCTAssertNil(ReleaseVersion("latest"))
    }
}
