import XCTest
@testable import macmcp

/// The closing MIME delimiter as evidence that a message is all here.
///
/// `complete` rests on `messageSize`, which Mail quotes in one of two units
/// without saying which (#53). Counting every LF as the CRLF it stood for is
/// what makes the server-side reading come out right, and it hands the other
/// reading one byte of slack per line break. That slack scales with the
/// message: measured on a 70.8 MB probe, `bytes_measured: 70,825,455` against
/// `message_size: 71,745,278` — **919,823 bytes**, reported `complete: true`,
/// `complete_basis: "wire"`. A fragment nearly a megabyte short passed, and
/// `mail_save_attachment` would have cut a file out of it.
///
/// Tightening the byte check was the wrong answer and #53 says why: it turns
/// any imprecision in `messageSize` into a permanent false `incomplete`, which
/// costs a caller `mail_save_attachment` entirely. The closing delimiter is a
/// different kind of evidence — structural, free, and independent of any count.
/// RFC 2046 requires a multipart body to end `--<boundary>--`, so a message
/// truncated anywhere before its last part does not have one whatever its bytes
/// add up to.
///
/// Verified live against the fixture, with a truncated multipart delivered into
/// Bob's Maildir: at a9cb85b `mail_get_source` reported
/// `complete: true, complete_basis: "wire", bytes_measured: 69618,
/// message_size: 70533` (915 bytes of slack, exactly the CRLF count) and
/// `mail_save_attachment` wrote a **51,186-byte** file for a 102,400-byte
/// attachment. The same message now reports `"unterminated"` and is refused,
/// while the intact copy reports `"wire+terminated"` and still saves all
/// 102,400 bytes.
final class MailSourceTerminationTests: XCTestCase {
    /// A `multipart/mixed` message with CRLF line endings, handed back the way
    /// Mail hands one back — every CRLF already collapsed to a bare LF, which
    /// is what creates the slack in the first place.
    private func multipart(parts: Int, terminated: Bool, boundary: String = "BOUND") -> Data {
        var lines = [
            "From: alice@relaytest.local",
            "To: bob@relaytest.local",
            "Subject: probe",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            ""
        ]
        for n in 0..<parts {
            lines += ["--\(boundary)", "Content-Type: text/plain", "", "part \(n)", ""]
        }
        if terminated { lines += ["--\(boundary)--", ""] }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The size Mail would report for `data` if the message it came from had
    /// `slack` bytes' worth of CRLF that this copy has as LF.
    private func wireSize(of data: Data, slack: Int) -> Int { data.count + slack }

    // MARK: - The hole

    func testATruncatedMultipartInsideTheWireSlackIsNotComplete() throws {
        let whole = multipart(parts: 20, terminated: true)
        // A fragment: everything up to the middle of the last part, with no
        // closing delimiter. Its bytes are well inside the slack the wire
        // reading allows, so no count can see it.
        let fragment = whole.prefix(whole.count - 40)
        let breaks = fragment.filter { $0 == 0x0A }.count
        let fidelity = MailService.sourceFidelity(
            Data(fragment),
            expectedSize: fragment.count + breaks
        )
        XCTAssertGreaterThan(breaks, 30, "the probe has to have enough line breaks to hide 40 bytes in")
        XCTAssertEqual(
            fidelity.completeBasis, "unterminated",
            "a multipart that stops before its own closing delimiter was read as complete"
        )
        XCTAssertFalse(fidelity.complete, "a fragment passed as the message")
        XCTAssertTrue(
            (fidelity.note ?? "").contains("--boundary--"),
            "nothing said what was missing: \(fidelity.note ?? "no note")"
        )
    }

    func testAWholeMultipartInsideTheWireSlackIsCompleteAndSaysWhy() throws {
        let whole = multipart(parts: 4, terminated: true)
        let breaks = whole.filter { $0 == 0x0A }.count
        let fidelity = MailService.sourceFidelity(whole, expectedSize: wireSize(of: whole, slack: breaks))
        XCTAssertEqual(fidelity.completeBasis, "wire+terminated")
        XCTAssertTrue(fidelity.complete)
        XCTAssertEqual(fidelity.slackBytes, breaks, "the slack is still reported, it just no longer matters")
    }

    // MARK: - What must not change

    func testASinglePartMessageIsStillJustWire() throws {
        // There is no structural marker to check, and inventing a stricter
        // reading for a message that cannot supply one would be the false
        // `incomplete` #53 refused to introduce.
        let data = Data("Subject: probe\nContent-Type: text/plain\n\nhello\nthere\n".utf8)
        let breaks = data.filter { $0 == 0x0A }.count
        let fidelity = MailService.sourceFidelity(data, expectedSize: data.count + breaks)
        XCTAssertEqual(fidelity.completeBasis, "wire")
        XCTAssertTrue(fidelity.complete)
    }

    func testAMultipartWithNoDeclaredBoundaryIsStillJustWire() throws {
        let data = Data("Subject: probe\nContent-Type: multipart/mixed\n\n--x\n\nbody\n".utf8)
        let breaks = data.filter { $0 == 0x0A }.count
        let fidelity = MailService.sourceFidelity(data, expectedSize: data.count + breaks)
        XCTAssertEqual(fidelity.completeBasis, "wire")
        XCTAssertTrue(fidelity.complete)
    }

    func testTheCheckIsNotAppliedWhenTheBytesReachTheSizeOnTheirOwn() throws {
        // On the `bytes` reading nothing is being assumed about units, so
        // there is no slack for a structural check to close -- and a sender
        // that left the closing line out of a message that is all here must
        // not lose it.
        let unterminated = multipart(parts: 2, terminated: false)
        let fidelity = MailService.sourceFidelity(unterminated, expectedSize: unterminated.count)
        XCTAssertEqual(fidelity.completeBasis, "bytes")
        XCTAssertTrue(fidelity.complete)
    }

    func testAFragmentTooShortForEitherReadingIsStillShort() throws {
        let whole = multipart(parts: 4, terminated: true)
        let fidelity = MailService.sourceFidelity(whole.prefix(200), expectedSize: whole.count * 2)
        XCTAssertEqual(fidelity.completeBasis, "short")
    }

    func testAnEmptySourceIsStillNone() throws {
        XCTAssertEqual(MailService.sourceFidelity(Data(), expectedSize: 100).completeBasis, "none")
    }

    // MARK: - Reading the delimiter itself

    func testTheDelimiterIsFoundThroughTrailingWhitespace() throws {
        var data = multipart(parts: 1, terminated: true)
        data.append(contentsOf: Data("\r\n \t\r\n".utf8))
        XCTAssertEqual(MIME.multipartIsTerminated(data), true)
    }

    func testTheDelimiterHasToStartALine() throws {
        // A body whose last line happens to end in the same characters is not
        // a closing delimiter.
        let data = Data("Content-Type: multipart/mixed; boundary=\"B\"\n\n--B\n\nsee --B--\n".utf8)
        XCTAssertEqual(MIME.multipartIsTerminated(data), false)
    }

    func testANonMultipartHasNoOpinion() throws {
        XCTAssertNil(MIME.multipartIsTerminated(Data("Content-Type: text/plain\n\nhello\n".utf8)))
        XCTAssertNil(MIME.multipartIsTerminated(Data()))
    }

    func testAQuotedBoundaryWithSpecialCharactersIsRead() throws {
        let data = multipart(parts: 1, terminated: true, boundary: "=_Part 1; x--y")
        XCTAssertEqual(MIME.multipartIsTerminated(data), true)
    }

    func testAnEpilogueReadsAsNotTerminated() throws {
        // Legal per RFC 2046 and vanishingly rare. It costs such a message the
        // stronger reading -- `"wire"` rather than `"wire+terminated"` -- and
        // never `complete: false`, because the basis only tightens when the
        // message is a multipart the check could answer for.
        var data = multipart(parts: 1, terminated: true)
        data.append(contentsOf: Data("this is an epilogue\n".utf8))
        XCTAssertEqual(MIME.multipartIsTerminated(data), false)
    }
}
