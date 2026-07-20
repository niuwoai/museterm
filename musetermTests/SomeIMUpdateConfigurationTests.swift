import Foundation
import Foundation
import Testing
@testable import museterm

struct SomeIMUpdateConfigurationTests {
    @Test
    func stableAppcastURLMatchesMuchtokenContract() {
        #expect(
            SomeIMUpdateConfiguration.feedURL?.absoluteString ==
                "https://some.im/api/v1/public/app-updates/appcast.xml?app_id=qterm&platform=macos&channel=stable"
        )
    }
}
