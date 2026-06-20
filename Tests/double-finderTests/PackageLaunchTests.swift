import XCTest
@testable import double_finder

@MainActor
final class PackageLaunchTests: XCTestCase {
    func testAppBundleIsLaunchablePackage() {
        // A system .app is a file package → should launch, not be entered.
        XCTAssertTrue(MainViewController.isLaunchablePackage("/System/Applications/Calculator.app"))
    }
    func testPlainDirectoryIsNotPackage() {
        XCTAssertFalse(MainViewController.isLaunchablePackage("/tmp"))
        XCTAssertFalse(MainViewController.isLaunchablePackage("/Applications"))
    }
}
