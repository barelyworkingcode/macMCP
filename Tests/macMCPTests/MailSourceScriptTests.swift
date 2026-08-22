import XCTest
@testable import macmcp

/// Cover for the generated source fetch (issue #31): `source()` hands back
/// whatever Mail has downloaded so far, so a message still arriving comes out as
/// a fragment — 838 bytes of a 300 KB message in the measurement that started
/// this — with nothing to distinguish it from a message that is 838 bytes long.
///
/// Run for real through `osascript` with `mail` bound to a stub whose `source()`
/// grows between calls, because the waiting is done in JavaScript and asserting
/// on the Swift that generates it would prove nothing. (It would also have caught
/// the `'\n'` that Swift turned into a real newline inside a JS string literal,
/// which took a live run to notice.)
final class MailSourceScriptTests: XCTestCase {
    private static let full = "Subject: whole\\nMIME-Version: 1.0\\n\\nbody\\n"
    /// `full` with a CR back on every LF: what Mail reports as `messageSize`.
    private static let fullWireSize = 38 + 4

    private func fetch(
        stub: String,
        messageId: String = "1",
        attempts: Int = 5,
        interval: Double = 0.01
    ) throws -> (output: String, reads: [[String: Any]]) {
        let script = """
        \(MailStubJS.source)
        \(stub)
        \(MailService.sourceScriptJXA(
            account: nil,
            mailbox: "INBOX",
            messageId: messageId,
            attempts: attempts,
            interval: interval
        ))
        JSON.stringify({output: sourceResult, reads: mail.log.sourceReads});
        """
        let payload = try JXA.runJSON(script)
        return (payload["output"] as? String ?? "", payload["reads"] as? [[String: Any]] ?? [])
    }

    /// A mailbox holding one message that arrives in `sources.count` stages.
    private func stub(sources: [String], size: Int?) -> String {
        let list = sources.map { "'\($0)'" }.joined(separator: ", ")
        return """
        var mail = makeMail({accounts: [
            {name: 'Alice', mailboxes: [
                {name: 'INBOX', messages: [{
                    id: 1, messageId: 'probe@relaytest.local',
                    sources: [\(list)]\(size.map { ", size: \($0)" } ?? "")
                }]}
            ]}
        ]});
        """
    }

    // MARK: - The defect

    func testAMessageStillDownloadingIsWaitedForRatherThanReturnedInPieces() throws {
        let (output, reads) = try fetch(
            stub: stub(sources: ["Subject: who", Self.full], size: Self.fullWireSize)
        )
        XCTAssertEqual(output, "MACMCP-SIZE:\(Self.fullWireSize)\n" + Self.full.replacingOccurrences(of: "\\n", with: "\n"))
        XCTAssertEqual(reads.count, 2, "the fragment was returned without a second look")
    }

    func testAMessageMailAlreadyHasInFullIsNotWaitedOn() throws {
        // The common case, and it must not pay for the fix: one read, no delay.
        let (output, reads) = try fetch(stub: stub(sources: [Self.full], size: Self.fullWireSize))
        XCTAssertTrue(output.hasPrefix("MACMCP-SIZE:\(Self.fullWireSize)\n"), output)
        XCTAssertEqual(reads.count, 1)
    }

    func testTheWaitIsBoundedAndTheFragmentIsStillReturned() throws {
        // A message Mail never finishes downloading -- a server that has gone
        // away, say. The wait has to end, and what there is comes back labelled
        // by the size line rather than being thrown away.
        let (output, reads) = try fetch(
            stub: stub(sources: ["Subject: partial\\n"], size: 100_000),
            attempts: 3
        )
        XCTAssertEqual(output, "MACMCP-SIZE:100000\nSubject: partial\n")
        XCTAssertEqual(reads.count, 4, "one read plus three attempts")

        // And Swift turns that into an explicit "this is a fragment".
        let split = MailService.splitSourceSizeMarker(Data(output.utf8))
        XCTAssertEqual(split.size, 100_000)
        XCTAssertNil(split.error)
        XCTAssertFalse(MailService.sourceFidelity(split.body, expectedSize: split.size).complete)
    }

    // MARK: - When Mail will not say how big the message is

    func testAMessageWithNoReadableSizeIsReturnedWithoutWaiting() throws {
        // `messageSize` raising is not evidence that anything is missing, so the
        // fetch neither waits nor claims the result is short.
        let (output, reads) = try fetch(stub: stub(sources: [Self.full], size: nil))
        XCTAssertTrue(output.hasPrefix("MACMCP-SIZE:-1\n"), output)
        XCTAssertEqual(reads.count, 1)

        let split = MailService.splitSourceSizeMarker(Data(output.utf8))
        XCTAssertNil(split.size)
        XCTAssertNil(split.error, "-1 is the script's own sentinel")
        XCTAssertTrue(MailService.sourceFidelity(split.body, expectedSize: split.size).complete)
    }

    // MARK: - The rest of the script still works

    func testAMissingMessageStillFailsBeforeAnySourceIsRead() throws {
        XCTAssertThrowsError(
            try fetch(stub: stub(sources: [Self.full], size: Self.fullWireSize), messageId: "404")
        ) { error in
            XCTAssertEqual(
                MailService.scriptErrorMessage((error as? JXA.Failure)?.stderr ?? ""),
                "message not found with id: 404"
            )
        }
    }
}
