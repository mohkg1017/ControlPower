# Repository Guidelines

## Project Structure & Module Organization
`ControlPower` is a macOS app with a privileged helper.
- `App/Sources`: SwiftUI app entry, views, and app-facing logic.
- `App/Resources`: app assets, `Info.plist`, privacy manifest, and entitlements.
- `Helper/Sources`: privileged helper executable.
- `Shared/Sources`: shared models, XPC protocol, and process utilities used by app/helper.
- `Tests`: unit tests for core behavior (XCTest + Swift Testing).
- `scripts`: release, install, entitlement checks, and profiling helpers.
- `project.yml`: source of truth for project config (regenerates `ControlPower.xcodeproj`).

## Build, Test, and Development Commands
- `xcodegen generate --spec project.yml`: regenerate the Xcode project after config/target changes.
- `xcodebuild -project ControlPower.xcodeproj -scheme ControlPower -configuration Debug -destination 'platform=macOS' build`: local debug build.
- `xcodebuild -project ControlPower.xcodeproj -scheme ControlPower -destination "platform=macOS,arch=$(uname -m)" test`: run unit tests.
- `DEVELOPER_ID_APP='Developer ID Application: ...' scripts/release.sh 1.0.0 1`: signed release build (optionally notarized with `NOTARY_PROFILE`).
- `scripts/install_to_applications.sh --target /Applications/ControlPower.app`: install built app.

## Coding Style & Naming Conventions
- Swift 6 with strict concurrency is enabled (`SWIFT_STRICT_CONCURRENCY=complete`); prefer explicit actor isolation and `Sendable` correctness.
- Follow existing Swift style: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for members.
- Keep UI-focused code in `App`, helper-only logic in `Helper`, and cross-target contracts in `Shared`.
- No repo-wide SwiftLint/SwiftFormat config currently; keep formatting consistent with nearby files.

## Testing Guidelines
- Add or update tests in `Tests/` when changing parsing, view-model behavior, helper communication, or power mutation flows.
- Use `test...` naming for XCTest methods; use descriptive `@Suite`/`@Test` names for Swift Testing.
- Run full `xcodebuild ... test` before opening a PR. For focused debugging, use `-only-testing:<Target>/<TestCase>/<testName>`.
- No strict coverage gate is configured; new logic should include regression-focused tests.

## Commit & Pull Request Guidelines
- Prefer concise Conventional Commit subjects (examples in history: `feat: ...`, `fix: ...`).
- Keep commits scoped to one logical change; include tests with behavior changes.
- PRs should include: summary, rationale, test evidence (build/test command results), and UI screenshots for visible changes.
- For release/helper changes, call out signing/notarization impact and rollback notes.

## Security & Configuration Tips
- Never commit signing secrets or notarization credentials.
- Use environment variables (`DEVELOPER_ID_APP`, `NOTARY_PROFILE`) or local env files for release automation.
- Validate release entitlements before distribution: `scripts/check-release-entitlements.sh /path/to/ControlPower.app`.
