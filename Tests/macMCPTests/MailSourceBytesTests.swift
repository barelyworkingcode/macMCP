import XCTest
@testable import macmcp

/// Regression cover for `mail_get_source` returning UTF-8 double-encoded bytes
/// (issue #5), which also corrupted `mail_save_attachment` for any attachment
/// that is not base64.
///
/// The corruption is invisible to an ASCII-only check — that is why it survived
/// this long — so every assertion here is byte-for-byte against a message whose
/// real bytes are known.
final class MailSourceBytesTests: XCTestCase {
    /// What osascript writes to stdout for a message Mail decoded as ISO-8859-1:
    /// the message's bytes, reinterpreted as Latin-1 characters and re-emitted
    /// as UTF-8, plus the newline osascript appends after any result.
    ///
    /// This is a *model* of the pipeline, and it can only ever prove that
    /// `decodeSourceBytes` inverts the model (#23). Two things keep it honest.
    /// `testTheTextChannelReallyDoesReEmitLatin1AsUtf8` checks the osascript
    /// half against real osascript rather than assuming it, and
    /// `MailSourceOnDiskTests` checks the whole pipeline against a message file
    /// on disk, which is the only evidence that can substantiate "byte-identical".
    ///
    /// Note what this helper does *not* model: what Mail does to the message
    /// before any of this. See `asMailWouldEmit`.
    private func asOsascriptWouldEmit(_ message: Data) -> Data {
        var out = Data()
        for byte in message {
            out.append(contentsOf: Array(String(UnicodeScalar(byte)).utf8))
        }
        out.append(0x0A)
        return out
    }

    /// The same, with Mail's own two lossy steps applied first: a NUL becomes
    /// `0x80`, and CRLF becomes LF.
    ///
    /// Measured, not assumed -- a message written into the fixture's Maildir
    /// with 21 CRLFs and one NUL comes back with 21 LFs, no CR, and `0x80`
    /// where the NUL was, and Mail's own `.emlx` copy of it already looks like
    /// that on disk. Nothing downstream can undo either, so these are the bytes
    /// `decodeSourceBytes` is really handed for such a message.
    private func asMailWouldEmit(_ message: Data) -> Data {
        var rendered = Data()
        var previous: UInt8 = 0
        for byte in message {
            if previous == 0x0D && byte != 0x0A { rendered.append(0x0D) }
            switch byte {
            case 0x00: rendered.append(0x80)
            case 0x0D: break
            default: rendered.append(byte)
            }
            previous = byte
        }
        if previous == 0x0D { rendered.append(0x0D) }
        return asOsascriptWouldEmit(rendered)
    }

    // MARK: - The reported defect

    func testEightBitBodyComesBackByteIdentical() {
        // The message from the issue: an 8bit text/plain part with non-ASCII in
        // several ranges -- Latin-1, an em dash, CJK, and an astral emoji.
        let message = Data("""
        From: alice@relaytest.local\r
        Subject: EIGHTBIT\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        Body with unicode: äöü — 日本語 café naïve 🚀

        """.utf8)

        let recovered = MailService.decodeSourceBytes(asOsascriptWouldEmit(message))
        XCTAssertEqual(recovered, message)
        // The specific mojibake from the issue: ä (c3 a4) arriving as c3 83 c2 a4.
        XCTAssertFalse(recovered.contains(subsequence: [0xC3, 0x83, 0xC2, 0xA4]))
        XCTAssertTrue(recovered.contains(subsequence: [0xC3, 0xA4]))
    }

    func testEightBitAttachmentPayloadIsNotInflated() {
        // The 23-byte payload from the issue, leading NUL included. An earlier
        // version of this test changed that NUL to 0x02 (#24), which quietly
        // removed the one byte value that does not round-trip from the fixture
        // that was supposed to be pinning the behaviour. It is back, and what
        // happens to it is asserted below rather than edited out.
        let payload = Data([
            0x00, 0x01, 0xC3, 0xBF, 0xC3, 0xBE, 0xC2, 0x80, 0x7F, 0xC3, 0x83, 0x28,
            0xC3, 0x9E, 0xC2, 0xAD, 0xC2, 0xBE, 0xC3, 0xAF, 0x0A, 0x41, 0x42
        ])
        var message = Data("""
        Content-Type: multipart/mixed; boundary="B"\r
        \r
        --B\r
        Content-Type: application/octet-stream; name="raw.bin"\r
        Content-Disposition: attachment; filename="raw.bin"\r
        Content-Transfer-Encoding: 8bit\r
        \r

        """.utf8)
        message.append(payload)
        message.append(Data("\r\n--B--\r\n".utf8))

        let recovered = MailService.decodeSourceBytes(asMailWouldEmit(message))
        let attachments = MIME.attachments(of: MIME.parse(recovered))
        XCTAssertEqual(attachments.count, 1)
        // 23 bytes, not the 41 bytes of garbage the issue reported as a success:
        // the defect this test exists for is the inflation, and it is fixed.
        XCTAssertEqual(attachments[0].data.count, 23)
        // Every byte survives except the NUL, which arrives as 0x80. This is the
        // current, measured behaviour, and it is pinned here so that a
        // regression or an upstream fix is visible instead of silent.
        XCTAssertEqual(attachments[0].data.dropFirst(), payload.dropFirst())
        XCTAssertEqual(attachments[0].data.first, 0x80)
        XCTAssertNotEqual(attachments[0].data, payload, "if this now passes, Mail has stopped destroying NULs")
    }

    // MARK: - The limits, pinned as they actually are

    func testANulInTheMessageComesBackAs0x80AndIsReportedAsAmbiguous() {
        // #5 was closed on a byte-identity claim. 253 of the 254 byte values a
        // probe message carried do round-trip; 0x00 does not, and the caller
        // cannot tell which of the 0x80s it got back used to be one. What is
        // asserted is therefore the pair: the byte that arrives, and the signal
        // that says it may not be the byte that was sent.
        var message = Data("Subject: nul\r\n\r\n".utf8)
        message.append(contentsOf: [0x41, 0x00, 0x42, 0x80, 0x43])

        let recovered = MailService.decodeSourceBytes(asMailWouldEmit(message))
        XCTAssertEqual(recovered.count, message.count - 2, "the CR of each of the two CRLFs comes off")
        XCTAssertEqual(Array(recovered.suffix(5)), [0x41, 0x80, 0x42, 0x80, 0x43])
        XCTAssertFalse(recovered.contains(0x00))

        let fidelity = MailService.sourceFidelity(recovered)
        XCTAssertEqual(fidelity.ambiguousNulBytes, 2, "the real 0x80 is a candidate too, and cannot be excluded")
        XCTAssertFalse(fidelity.exact)
    }

    func testCrlfComesBackAsLfAndIsReportedAsSuch() {
        let message = Data("From: a@b.c\r\nSubject: crlf\r\n\r\nbody\r\n".utf8)
        let recovered = MailService.decodeSourceBytes(asMailWouldEmit(message))
        XCTAssertFalse(recovered.contains(0x0D), "Mail returns LF; nothing downstream restores the CR")
        XCTAssertEqual(recovered, Data("From: a@b.c\nSubject: crlf\n\nbody\n".utf8))
        XCTAssertEqual(MailService.sourceFidelity(recovered).lineEndings, "lf")
    }

    // MARK: - The model, checked against the real channel

    func testTheTextChannelReallyDoesReEmitLatin1AsUtf8() throws {
        // The half of `asOsascriptWouldEmit` that can be checked without Mail:
        // a JS string holding U+0000 to U+00FF, written to stdout by real
        // osascript. If this ever stops matching, every test in this file that
        // relies on the model is testing nothing.
        let script = """
        var s = ''; for (var i = 0; i <= 0xFF; i++) { if (i === 0x0A || i === 0x0D) continue; s += String.fromCharCode(i); }
        s;
        """
        let emitted = try JXA.runRaw(script)

        var latin1 = Data()
        for byte in UInt8(0)...UInt8(255) where byte != 0x0A && byte != 0x0D { latin1.append(byte) }
        XCTAssertEqual(emitted, asOsascriptWouldEmit(latin1))

        // And therefore: what the channel hands over inverts cleanly, NUL and
        // all. The NUL loss is Mail's, not the channel's -- which is what the
        // decodeSourceBytes comment used to get wrong.
        XCTAssertEqual(MailService.decodeSourceBytes(emitted), latin1)
        XCTAssertTrue(latin1.contains(0x00))
    }

    func testBase64AttachmentStaysByteExact() {
        // The control from the issue: base64 is pure ASCII, so it was already
        // correct and must stay correct.
        let message = Data("""
        Content-Type: application/octet-stream; name="ok.bin"\r
        Content-Disposition: attachment; filename="ok.bin"\r
        Content-Transfer-Encoding: base64\r
        \r
        aGVsbG8gd29ybGQK\r

        """.utf8)
        let recovered = MailService.decodeSourceBytes(asOsascriptWouldEmit(message))
        XCTAssertEqual(recovered, message)
        XCTAssertEqual(
            MIME.attachments(of: MIME.parse(recovered)).first?.data,
            Data("hello world\n".utf8)
        )
    }

    // MARK: - The osascript newline

    func testTrailingNewlineFromOsascriptIsNotPartOfTheMessage() {
        let message = Data("Subject: x\r\n\r\nbody\r\n".utf8)
        XCTAssertEqual(MailService.decodeSourceBytes(asOsascriptWouldEmit(message)), message)
        // Exactly one newline is added, whether or not the value already ended
        // in one, so exactly one comes off.
        let noTrailingNewline = Data("Subject: x\r\n\r\nbody".utf8)
        XCTAssertEqual(
            MailService.decodeSourceBytes(asOsascriptWouldEmit(noTrailingNewline)),
            noTrailingNewline
        )
    }

    // MARK: - Guards

    func testStdoutThatIsNotValidUTF8IsLeftAlone() {
        // A lone 0xFF is not a UTF-8 sequence. Nothing is known about what this
        // is, so nothing is done to it beyond dropping osascript's newline.
        var data = Data([0x41, 0xFF, 0x42])
        data.append(0x0A)
        XCTAssertEqual(MailService.decodeSourceBytes(data), Data([0x41, 0xFF, 0x42]))
    }

    func testTextHoldingScalarsAboveLatin1IsLeftAlone() {
        // What a future Mail that decoded the source correctly would emit: real
        // characters, not Latin-1 stand-ins. Re-encoding those as Latin-1 would
        // fail, and the bytes are handed back untouched instead of mangled.
        var data = Data("Subject: 日本語\r\n".utf8)
        data.append(0x0A)
        XCTAssertEqual(MailService.decodeSourceBytes(data), Data("Subject: 日本語\r\n".utf8))
    }

    func testAsciiOnlySourceIsUnchanged() {
        let message = Data("From: a@b.c\r\nSubject: plain\r\n\r\nhello\r\n".utf8)
        XCTAssertEqual(MailService.decodeSourceBytes(asOsascriptWouldEmit(message)), message)
    }
}

private extension Data {
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        let bytes = [UInt8](self)
        for start in 0...(bytes.count - needle.count) where Array(bytes[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
