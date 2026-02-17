import XCTest
@testable import ControlPower

final class ControlPowerTests: XCTestCase {
    func testPMSetParserReadsValues() {
        let text = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         lidwake              0
        """
        let snapshot = PMSetParser.parse(text)
        XCTAssertEqual(snapshot.disableSleep, true)
        XCTAssertEqual(snapshot.lidWake, false)
    }
}
