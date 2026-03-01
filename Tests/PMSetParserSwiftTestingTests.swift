import Testing
@testable import ControlPowerCore

@Suite("PMSetParser")
struct PMSetParserSwiftTestingTests {
    struct ParseCase: Sendable {
        let input: String
        let expectedDisableSleep: Bool?
        let expectedLidWake: Bool?
    }

    @Test(
        "Parses pmset values from representative outputs",
        arguments: [
            ParseCase(
                input: """
                System-wide power settings:
                 SleepDisabled\t\t1
                Currently in use:
                 lidwake              0
                """,
                expectedDisableSleep: true,
                expectedLidWake: false
            ),
            ParseCase(
                input: """
                System-wide power settings:
                 standby              1
                """,
                expectedDisableSleep: nil,
                expectedLidWake: nil
            ),
            ParseCase(
                input: """
                Currently in use:
                 sleep                0
                 lidwake              1
                """,
                expectedDisableSleep: true,
                expectedLidWake: true
            ),
            ParseCase(
                input: """
                Currently in use:
                 sleep                15
                 lidwake              1
                """,
                expectedDisableSleep: false,
                expectedLidWake: true
            ),
            ParseCase(
                input: """

                System-wide power settings:
                 SleepDisabled 0
                 lidwake       1

                """,
                expectedDisableSleep: false,
                expectedLidWake: true
            )
        ]
    )
    func parsesExpectedValues(_ testCase: ParseCase) {
        let snapshot = PMSetParser.parse(testCase.input)
        #expect(snapshot.disableSleep == testCase.expectedDisableSleep)
        #expect(snapshot.lidWake == testCase.expectedLidWake)
    }

    @Test("Trims summary output")
    func trimsSummary() {
        let text = """

        System-wide power settings:
         SleepDisabled 0
         lidwake       1

        """

        let snapshot = PMSetParser.parse(text)
        #expect(snapshot.summary.hasPrefix("System-wide power settings:"))
        #expect(!snapshot.summary.hasSuffix("\n"))
    }
}
