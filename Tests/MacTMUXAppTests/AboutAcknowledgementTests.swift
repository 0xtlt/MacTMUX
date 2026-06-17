@testable import MacTMUXApp
import XCTest

final class AboutAcknowledgementTests: XCTestCase {
    func testGhosttyAcknowledgementIsPresent() {
        let acknowledgement = AboutAcknowledgements.thirdParty.first { $0.name == "Ghostty / libghostty" }

        XCTAssertNotNil(acknowledgement)
        XCTAssertEqual(acknowledgement?.licenseName, "MIT License")
        XCTAssertEqual(
            acknowledgement?.copyright,
            "Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors"
        )
        XCTAssertEqual(acknowledgement?.url?.absoluteString, "https://github.com/ghostty-org/ghostty")
    }

    func testMITLicenseAllowsCommercialDistributionText() {
        let licenseText = AboutAcknowledgements.mitLicenseText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        XCTAssertTrue(licenseText.contains("sell copies of the Software"))
        XCTAssertTrue(licenseText.contains("The above copyright notice"))
        XCTAssertTrue(licenseText.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }
}
