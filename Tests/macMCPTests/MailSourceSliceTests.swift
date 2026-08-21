import XCTest
@testable import macmcp

/// Regression cover for `max_bytes` truncation in `mail_get_source` (issue #6).
///
/// A cut landing inside a multi-byte UTF-8 sequence made the `.utf8` decode fail
/// for the *whole* slice, and the `.isoLatin1` fallback then reinterpreted every
/// non-ASCII byte in it — so one split character corrupted the entire response,
/// and `bytes_returned` reported a number that did not describe the string that
/// came back (1601 for a 1672-byte string).
///
/// Independent of the double-encoding fix: this reproduced on a source that was
/// already byte-correct.
final class MailSourceSliceTests: XCTestCase {
    /// Headers plus a long run of `é`, the shape the issue swept across. The run
    /// starts at an odd offset from the two-byte grid, so both parities occur.
    private let source: Data = {
        var data = Data("Subject: accents\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
        data.append(Data(String(repeating: "é", count: 400).utf8))
        data.append(Data("\r\n".utf8))
        return data
    }()

    // MARK: - The reported defect

    func testEveryOffsetReturnsATruePrefixOfTheSource() {
        // The issue's sweep, one byte at a time across the run. Before the fix,
        // every offset that split a sequence returned a re-decoded copy of the
        // whole slice instead of a prefix.
        for maxBytes in 60...140 {
            let slice = MailService.sourceSlice(source, maxBytes: maxBytes)
            XCTAssertEqual(slice.encoding, "utf-8", "max_bytes \(maxBytes)")
            let returned = Data(slice.text.utf8)
            XCTAssertEqual(
                returned, source.prefix(slice.bytesReturned),
                "max_bytes \(maxBytes): source is not a prefix of the message"
            )
            XCTAssertLessThanOrEqual(slice.bytesReturned, maxBytes, "max_bytes \(maxBytes)")
            XCTAssertGreaterThanOrEqual(
                slice.bytesReturned, maxBytes - 3,
                "max_bytes \(maxBytes): trimmed back further than one character"
            )
        }
    }

    func testBytesReturnedDescribesTheStringThatCameBack() {
        // The exact discrepancy from the issue: a reported count that belonged
        // to the slice rather than to the text.
        for maxBytes in 60...140 {
            let slice = MailService.sourceSlice(source, maxBytes: maxBytes)
            XCTAssertEqual(
                slice.bytesReturned, Data(slice.text.utf8).count,
                "max_bytes \(maxBytes): bytes_returned disagrees with the source it describes"
            )
        }
    }

    func testASplitSequenceIsDroppedRatherThanHalfReturned() {
        // 53 bytes of header, then two-byte characters: 54 lands mid-sequence.
        let headerLength = Data("Subject: accents\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8).count
        let slice = MailService.sourceSlice(source, maxBytes: headerLength + 1)
        XCTAssertEqual(slice.bytesReturned, headerLength)
        XCTAssertFalse(slice.text.contains("\u{FFFD}"), "no replacement characters should appear")
    }

    // MARK: - Sources that are not UTF-8 at all

    func testNonUTF8SourceIsReturnedAndSaidToBeLatin1() {
        // A Latin-1 message: the fallback is legitimate here, and is now
        // disclosed so bytes_returned can be read correctly.
        var latin1 = Data("Subject: caf".utf8)
        latin1.append(0xE9)  // 'é' in ISO-8859-1, not valid UTF-8
        latin1.append(Data("\r\n".utf8))

        let slice = MailService.sourceSlice(latin1, maxBytes: 1000)
        XCTAssertEqual(slice.encoding, "iso-8859-1")
        XCTAssertEqual(slice.bytesReturned, latin1.count)
        XCTAssertEqual(slice.text.data(using: .isoLatin1), latin1)
    }

    func testNonUTF8SourceIsNotEatenAByteAtATime() {
        // The trim is bounded at three bytes, so a slice that is not UTF-8
        // anywhere still comes back at (near) full length rather than empty.
        let noise = Data((0..<200).map { _ in UInt8.random(in: 0x80...0xFF) })
        let slice = MailService.sourceSlice(noise, maxBytes: 100)
        XCTAssertGreaterThanOrEqual(slice.bytesReturned, 97)
    }

    // MARK: - Boundaries

    func testUntruncatedSourceIsNeverTrimmed() {
        let slice = MailService.sourceSlice(source, maxBytes: source.count + 500)
        XCTAssertEqual(slice.bytesReturned, source.count)
        XCTAssertEqual(Data(slice.text.utf8), source)
    }

    func testEmptySource() {
        let slice = MailService.sourceSlice(Data(), maxBytes: 1000)
        XCTAssertEqual(slice.bytesReturned, 0)
        XCTAssertEqual(slice.text, "")
    }

    // MARK: - The undocumented floor

    func testMaxBytesFloorIsGone() {
        // `max_bytes: 10` used to be clamped up to 1000, which the schema said
        // nothing about.
        XCTAssertEqual(MailService.clampMaxBytes(10), 10)
        XCTAssertEqual(MailService.sourceSlice(source, maxBytes: 10).bytesReturned, 10)
    }

    func testMaxBytesDefaultAndCeilingAreUnchanged() {
        XCTAssertEqual(MailService.clampMaxBytes(nil), 100_000)
        XCTAssertEqual(MailService.clampMaxBytes(9_000_000), 2_000_000)
        // Still at least one byte: `prefix` would trap on a negative.
        XCTAssertEqual(MailService.clampMaxBytes(0), 1)
        XCTAssertEqual(MailService.clampMaxBytes(-5), 1)
    }
}
