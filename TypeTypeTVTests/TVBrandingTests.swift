import UIKit
import XCTest

@testable import TypeTypeTV

final class TVBrandingTests: XCTestCase {
    func testOfficialSidebarLogoIsBundled() {
        let logo = UIImage(named: "TypeTypeLogo")
        XCTAssertNotNil(logo,
                        "The official TypeType mark should be available as a tvOS image asset")
        XCTAssertEqual(logo?.size.width, logo?.size.height,
                       "The sidebar icon should use square, uncropped artwork")
    }
}
