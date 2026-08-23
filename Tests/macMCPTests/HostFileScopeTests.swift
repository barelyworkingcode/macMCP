import Foundation
import XCTest
@testable import macmcp

/// `file_dirs` outside mail: the three tools that opened a file on this host
/// and were bounded by nothing.
///
/// `capture_screenshot` and `capture_audio` took an unbounded absolute `path`
/// and wrote to it; `utilities_play_sound` took an unbounded absolute `path`
/// and read from it. That is ADR-011 finding 1 -- the arbitrary host write it
/// named as **escalation** rather than exfiltration and closed for
/// `mail_save_attachment` -- reappearing one service over, and the live attempt
/// against it passed every relay and macMCP layer before dying on the tool's
/// own backend.
///
/// **Nothing here spawns `screencapture` or `afrecord`.** Every case is a
/// refusal, which returns before `runProcess`; the admitting direction is
/// pinned on `HostFileScope` itself, where there is no subprocess underneath.
final class HostFileScopeTests: XCTestCase {
    private func registry() -> ToolRegistry {
        let registry = ToolRegistry()
        CaptureService.register(registry)
        UtilitiesService.register(registry)
        return registry
    }

    /// `_meta` present with nothing else in it: relay injects `project_id` on
    /// every mediated call, so this is a profile that carries no `file_dirs`.
    private let mediatedWithNoDirs: JSONObject = ["project_id": .string("prof_hermes")]

    private func dirs(_ paths: [String]) -> JSONObject {
        ["project_id": .string("prof_hermes"), "file_dirs": .array(paths.map { .string($0) })]
    }

    private func text(_ result: MCPCallResult) -> String {
        result.content.map(\.text).joined()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-hostfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
    }

    // MARK: - The hole itself

    /// The write the validator reached: an absolute path anywhere on the host,
    /// through a profile that was granted `capture_*` and nothing filesystem
    /// shaped. It must be refused, and refused as a **violation** -- a client
    /// naming a path outside its scope is a client probing a boundary.
    func testAnAbsolutePathOutsideFileDirsIsRefusedForEveryOneOfTheThreeTools() throws {
        let root = try temporaryDirectory()
        let reg = registry()
        let cases: [(String, JSONObject)] = [
            ("capture_screenshot", ["path": .string("/tmp/zsec-shot.png")]),
            ("capture_audio", ["path": .string("/tmp/zsec-rec.m4a"), "duration": .int(1)]),
            ("utilities_play_sound", ["path": .string("/etc/passwd")])
        ]
        for (tool, arguments) in cases {
            let result = reg.call(name: tool, arguments: arguments, meta: dirs([root.path]))
            XCTAssertEqual(result.isError, true, tool)
            XCTAssertEqual(result.meta?["scope_violation"], .bool(true), tool)
            XCTAssertTrue(text(result).contains("outside the directories"), "\(tool): \(text(result))")
        }
    }

    /// Decision 4: a mediated call carrying no `file_dirs` is a refusal, never
    /// "anywhere". These three are in the field's `applies_to`, so relay denies
    /// them outright too -- and this is macMCP's own independent check, which
    /// is the whole point of decision 4 ("one check, not two").
    func testAMediatedCallWithNoFileDirsCannotOpenAFileAtAll() {
        let reg = registry()
        let cases: [(String, JSONObject)] = [
            // No `path` either: the default location is not an escape hatch.
            ("capture_screenshot", [:]),
            ("capture_audio", ["duration": .int(1)]),
            ("utilities_play_sound", ["path": .string("/tmp/x.m4a")])
        ]
        for (tool, arguments) in cases {
            let result = reg.call(name: tool, arguments: arguments, meta: mediatedWithNoDirs)
            XCTAssertEqual(result.isError, true, tool)
            XCTAssertEqual(result.meta?["scope_violation"], .bool(true), tool)
            XCTAssertTrue(
                text(result).contains("refusal rather than \"anywhere\""),
                "\(tool): \(text(result))"
            )
        }
    }

    /// The three tools are declared as governed by the field, which is what
    /// makes relay deny them as well. The rule for being in that list is that
    /// the tool cannot function without a directory: a capture's `path` is
    /// optional in the schema and unavoidable in fact.
    func testTheThreeToolsAreDeclaredAsGovernedByFileDirs() {
        for tool in ["capture_screenshot", "capture_audio", "utilities_play_sound"] {
            XCTAssertTrue(restrictFieldsGoverning(tool: tool).contains("file_dirs"), tool)
        }
    }

    // MARK: - An unmediated call is untouched

    /// macmcp on a bare stdio pipe is same-user local access, equivalent to
    /// running `screencapture` in a shell. Every existing caller is this one
    /// and none of the above may cost it anything.
    func testAnUnmediatedCallOpensWhateverItAlwaysCould() {
        XCTAssertEqual(
            HostFileScope.resolve("/tmp/anything.png", scope: .none, use: .write, what: "screenshot"),
            .use("/tmp/anything.png")
        )
        XCTAssertEqual(
            HostFileScope.resolve("/etc/passwd", scope: .none, use: .read, what: "audio file"),
            .use("/etc/passwd")
        )
        XCTAssertEqual(
            HostFileScope.resolveDefault(
                directory: "~/Desktop", filename: "shot.png", scope: .none, what: "screenshot"),
            .use(NSString(string: "~/Desktop/shot.png").expandingTildeInPath)
        )
    }

    // MARK: - The path the caller did not name

    /// A tool's own default is not a choice the caller made, so an absent
    /// `path` resolves **to the scope** -- the same three steps
    /// `ScopedRows.defaultTarget` resolves an absent `calendar_name` in.
    /// Refusing instead would mean no scoped client could screenshot without
    /// first knowing its own `file_dirs`, which it has no way to ask for.
    func testAnAbsentPathResolvesToTheSingleDirectoryInScope() throws {
        let root = try temporaryDirectory()
        guard case .use(let path) = HostFileScope.resolveDefault(
            directory: "~/Desktop", filename: "shot.png",
            scope: ResourceScope.parse(dirs([root.path])), what: "screenshot"
        ) else { return XCTFail("one directory in scope is the only answer") }
        XCTAssertEqual(path, root.appendingPathComponent("shot.png").path)
    }

    /// When the tool's own default *is* inside the scope it wins, because an
    /// operator who granted the directory the user's screenshots go to got
    /// what they meant.
    func testTheToolsOwnDefaultIsUsedWhenItIsInsideTheScope() throws {
        let root = try temporaryDirectory()
        let other = try temporaryDirectory()
        guard case .use(let path) = HostFileScope.resolveDefault(
            directory: root.path, filename: "shot.png",
            scope: ResourceScope.parse(dirs([other.path, root.path])), what: "screenshot"
        ) else { return XCTFail("a default inside the scope satisfies it") }
        XCTAssertEqual(path, root.appendingPathComponent("shot.png").path)
    }

    /// Several directories and a default in none of them: the caller is asked,
    /// with the directories named. It is an **error and not a violation** --
    /// nothing was probed, the caller simply did not say where -- which is why
    /// `HostFileScope.Outcome` does not reuse `ResourceScope.Decision`.
    func testSeveralDirectoriesAndNoDefaultAsksRatherThanPicking() throws {
        let a = try temporaryDirectory()
        let b = try temporaryDirectory()
        let result = registry().call(
            name: "capture_screenshot", arguments: [:], meta: dirs([a.path, b.path]))
        XCTAssertEqual(result.isError, true)
        XCTAssertNil(result.meta?["scope_violation"], "omitting an argument is not a probe")
        XCTAssertTrue(text(result).contains("Pass `path`"), text(result))
        XCTAssertTrue(text(result).contains(a.path), text(result))
        XCTAssertTrue(text(result).contains(b.path), text(result))
    }

    // MARK: - The walk is the same one, so its edges are the same

    /// A symlink out of the allowed directory is out of it. Component-by-
    /// component `realPath` is what makes that true for a path that does not
    /// exist yet, which is the normal case for a file about to be created --
    /// and a client does not have to plant the link, because a project
    /// directory is an ordinary checkout and repositories contain symlinks.
    func testASymlinkOutOfFileDirsIsNotAPlaceAScreenshotMayGo() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let link = root.appendingPathComponent("way-out")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        guard case .refuse = HostFileScope.resolve(
            link.appendingPathComponent("shot.png").path,
            scope: ResourceScope.parse(dirs([root.path])), use: .write, what: "screenshot"
        ) else { return XCTFail("a symlink out of the allowed directory is out of it") }
    }

    /// A `file_dirs` entry that bounds nothing is an operator mistake, so it
    /// is an error without the violation marker -- and both services say the
    /// same sentence about it, which is why the two live on `ResourceScope`.
    func testAnUnusableFileDirsEntryReadsTheSameThroughCaptureAsThroughMail() {
        for (entry, phrase) in [(".", "not an absolute path"), ("/", "bounds nothing")] {
            let scope = ResourceScope.parse(dirs([entry]))
            guard case .error(let capture) = HostFileScope.resolve(
                "/tmp/x.png", scope: scope, use: .write, what: "screenshot"
            ) else { return XCTFail("\(entry) bounds nothing") }
            guard case .misconfigured(let mail) = scope.writeDestination("/tmp/x.eml") else {
                return XCTFail("\(entry) bounds nothing for mail either")
            }
            XCTAssertEqual(capture, mail)
            XCTAssertTrue(capture.contains(phrase), capture)
        }
        // And through the registry it carries no violation marker.
        let result = registry().call(
            name: "capture_screenshot",
            arguments: ["path": .string("/tmp/x.png")],
            meta: dirs(["."])
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertNil(result.meta?["scope_violation"], "an operator typo is not a probe")
    }

    /// A path inside the scope is allowed, in both directions. This is the one
    /// admitting case, taken at the seam so no subprocess runs.
    func testAPathInsideFileDirsIsAllowedInBothDirections() throws {
        let root = try temporaryDirectory()
        let inside = root.appendingPathComponent("shot.png").path
        let scope = ResourceScope.parse(dirs([root.path]))
        XCTAssertEqual(
            HostFileScope.resolve(inside, scope: scope, use: .write, what: "screenshot"),
            .use(inside)
        )
        XCTAssertEqual(
            HostFileScope.resolve(inside, scope: scope, use: .read, what: "audio file"),
            .use(inside)
        )
    }
}
