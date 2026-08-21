import XCTest
@testable import macmcp

/// Cover for the two ways a fetched source is *not* the message the server
/// holds, which #5 was closed as if it were: a NUL arriving as `0x80`, and CRLF
/// arriving as LF.
///
/// Neither is recoverable — both happen inside Mail — so what is under test is
/// that the caller is told, in a signal they can act on, rather than in a code
/// comment. The numbers below come from a message written byte by byte into the
/// testMail fixture's Maildir and fetched back; `MailSourceOnDiskTests` is the
/// test that measures them against the real thing.
final class MailSourceFidelityTests: XCTestCase {
    // MARK: - Line endings

    func testACrlfSourceIsReportedAsExact() {
        let fidelity = MailService.sourceFidelity(Data("Subject: x\r\n\r\nbody\r\n".utf8))
        XCTAssertEqual(fidelity.lineEndings, "crlf")
        XCTAssertTrue(fidelity.exact)
        XCTAssertNil(fidelity.note)
    }

    func testAnLfSourceIsNotClaimedToBeExact() {
        // What Mail actually returns for every message: 21 CRLFs on disk came
        // back as 21 LFs. A caller comparing against the server's copy needs to
        // know before, not after.
        let fidelity = MailService.sourceFidelity(Data("Subject: x\n\nbody\n".utf8))
        XCTAssertEqual(fidelity.lineEndings, "lf")
        XCTAssertFalse(fidelity.exact)
        XCTAssertTrue(try XCTUnwrap(fidelity.note).contains("CRLF"), fidelity.note ?? "")
    }

    func testMixedLineEndingsAreNotPassedOffAsEither() {
        let fidelity = MailService.sourceFidelity(Data("a\r\nb\nc\r\n".utf8))
        XCTAssertEqual(fidelity.lineEndings, "mixed")
        XCTAssertFalse(fidelity.exact)
    }

    func testABareCarriageReturnCountsAsMixedRatherThanCrlf() {
        // A lone CR is not a line ending Mail produces, so it must not be
        // reported as the clean case.
        XCTAssertEqual(MailService.sourceFidelity(Data("a\rb".utf8)).lineEndings, "mixed")
        XCTAssertEqual(MailService.sourceFidelity(Data("a\r\nb\r".utf8)).lineEndings, "mixed")
    }

    func testDataWithNoLineBreaksIsNotAccusedOfAnything() {
        let fidelity = MailService.sourceFidelity(Data("Subject: x".utf8))
        XCTAssertEqual(fidelity.lineEndings, "none")
        XCTAssertTrue(fidelity.exact)
    }

    // MARK: - The NUL, which is ambiguous rather than merely lost

    func testEvery0x80IsCountedAsAPossibleLostNul() {
        // 0x80 is where a NUL lands. It is also a perfectly ordinary byte, and
        // nothing after the fact can say which one a given 0x80 was -- so the
        // count is reported and the ambiguity is stated, rather than either
        // being guessed at.
        let fidelity = MailService.sourceFidelity(Data([0x41, 0x80, 0x42, 0x80, 0x0D, 0x0A]))
        XCTAssertEqual(fidelity.ambiguousNulBytes, 2)
        XCTAssertFalse(fidelity.exact)
        let note = try! XCTUnwrap(fidelity.note)
        XCTAssertTrue(note.contains("2 byte(s)"), note)
        XCTAssertTrue(note.contains("indistinguishable"), note)
    }

    func testASourceWithNo0x80IsNotWarnedAbout() {
        let fidelity = MailService.sourceFidelity(Data("Subject: plain\r\n".utf8))
        XCTAssertEqual(fidelity.ambiguousNulBytes, 0)
        XCTAssertTrue(fidelity.exact)
    }

    func testAnActualNulIsNotCountedAsItsOwnReplacement() {
        // If a future Mail stops destroying NULs, the bytes arrive with 0x00 in
        // them and there is nothing ambiguous left to report.
        let fidelity = MailService.sourceFidelity(Data([0x41, 0x00, 0x42, 0x0D, 0x0A]))
        XCTAssertEqual(fidelity.ambiguousNulBytes, 0)
        XCTAssertTrue(fidelity.exact)
    }

    // MARK: - The shape a caller sees

    func testTheReportedObjectCarriesBothCaveatsAtOnce() throws {
        let dict = MailService.sourceFidelity(Data([0x41, 0x80, 0x0A, 0x42, 0x0A])).dict
        XCTAssertEqual(dict["exact"] as? Bool, false)
        XCTAssertEqual(dict["line_endings"] as? String, "lf")
        XCTAssertEqual(dict["ambiguous_nul_bytes"] as? Int, 1)
        let note = try XCTUnwrap(dict["note"] as? String)
        XCTAssertTrue(note.contains("CRLF"), note)
        XCTAssertTrue(note.contains("0x80"), note)
    }

    func testAnExactResultCarriesNoNote() {
        let dict = MailService.sourceFidelity(Data("Subject: x\r\n".utf8)).dict
        XCTAssertEqual(dict["exact"] as? Bool, true)
        XCTAssertNil(dict["note"])
    }
}
