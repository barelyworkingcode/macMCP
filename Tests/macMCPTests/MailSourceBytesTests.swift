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
    private func asOsascriptWouldEmit(_ message: Data) -> Data {
        var out = Data()
        for byte in message {
            out.append(contentsOf: Array(String(UnicodeScalar(byte)).utf8))
        }
        out.append(0x0A)
        return out
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
        // The 23-byte payload from the issue, minus its leading NUL: a NUL does
        // not survive the osascript text channel at all (it arrives as U+0080),
        // which is a separate and unrecoverable limit, documented on
        // decodeSourceBytes.
        let payload = Data([
            0x02, 0x01, 0xC3, 0xBF, 0xC3, 0xBE, 0xC2, 0x80, 0x7F, 0xC3, 0x83, 0x28,
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

        let recovered = MailService.decodeSourceBytes(asOsascriptWouldEmit(message))
        let attachments = MIME.attachments(of: MIME.parse(recovered))
        XCTAssertEqual(attachments.count, 1)
        // 23 bytes, not the 41 bytes of garbage the issue reported as a success.
        XCTAssertEqual(attachments[0].data, payload)
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
