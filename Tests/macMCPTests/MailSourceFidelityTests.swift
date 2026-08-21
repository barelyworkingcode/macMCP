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

    // MARK: - A message Mail has not finished downloading (#31)

    func testASourceShorterThanTheMessageIsReportedAsIncomplete() throws {
        // 838 bytes of a 300 KB message, which is what `source()` returns while
        // Mail is still fetching. Nothing in the old response distinguished that
        // from an 838-byte message.
        let fragment = Data(repeating: 0x41, count: 800) + Data("\n".utf8)
        let fidelity = MailService.sourceFidelity(fragment, expectedSize: 300_511)
        XCTAssertFalse(fidelity.complete)
        XCTAssertFalse(fidelity.exact)
        let note = try XCTUnwrap(fidelity.note)
        XCTAssertTrue(note.contains("fragment"), note)
        XCTAssertTrue(note.contains("300511"), note)
    }

    func testTheReturnedBytesAreWeighedInTheUnitsMailQuotes() {
        // messageSize is the wire size, and the bytes here came through a
        // CRLF->LF transform, so one CR goes back on for each LF before the
        // comparison. Without that every complete message would look 1 byte per
        // line short and report itself a fragment.
        let source = Data("From: a@b.c\nSubject: x\n\nbody\n".utf8)
        XCTAssertEqual(source.count, 29)
        let fidelity = MailService.sourceFidelity(source, expectedSize: 33)
        XCTAssertEqual(fidelity.wireSize, 33, "4 LFs, so 4 CRs come back")
        XCTAssertTrue(fidelity.complete)
    }

    func testASourceMailCannotSizeIsNotAccusedOfBeingIncomplete() {
        // `messageSize` failing is not evidence of anything, and reporting a
        // guess as a fact is what this whole seam exists to stop.
        let fidelity = MailService.sourceFidelity(Data("Subject: x\r\n".utf8), expectedSize: nil)
        XCTAssertTrue(fidelity.complete)
        XCTAssertTrue(fidelity.exact)
        XCTAssertNil(fidelity.dict["message_size"])
    }

    func testCompletenessIsReportedEvenWhenNothingElseIsWrong() {
        let dict = MailService.sourceFidelity(Data("Subject: x\r\n".utf8), expectedSize: 12).dict
        XCTAssertEqual(dict["complete"] as? Bool, true)
        XCTAssertEqual(dict["message_size"] as? Int, 12)
    }

    // MARK: - The size line the fetch script prints

    func testTheSizeLineIsSplitOffTheFrontOfTheSource() {
        var raw = Data("MACMCP-SIZE:418\n".utf8)
        raw.append(Data("Return-Path: <a@b.c>\nSubject: x\n".utf8))
        let (size, body) = MailService.splitSourceSizeMarker(raw)
        XCTAssertEqual(size, 418)
        XCTAssertEqual(body, Data("Return-Path: <a@b.c>\nSubject: x\n".utf8))
    }

    func testAMessageMailWouldNotSizeComesBackWithNoSizeAndAllItsBytes() {
        // The script prints -1 when `messageSize` raised. That is "unknown",
        // not "zero bytes", and the source is untouched either way.
        var raw = Data("MACMCP-SIZE:-1\n".utf8)
        raw.append(Data("Subject: x\n".utf8))
        let (size, body) = MailService.splitSourceSizeMarker(raw)
        XCTAssertNil(size)
        XCTAssertEqual(body, Data("Subject: x\n".utf8))
    }

    func testAFirstLineThatMerelyLooksLikeTheMarkerIsNotEaten() {
        // A message really can begin with anything, and losing its first line to
        // a loose prefix match would be a new corruption in the code that exists
        // to stop corruption going unreported.
        for impostor in [
            "MACMCP-SIZE:not-a-number\nSubject: x\n",
            "MACMCP-SIZE\nSubject: x\n",
            "X-MACMCP-SIZE:418\nSubject: x\n",
            "Subject: MACMCP-SIZE:418\n"
        ] {
            let raw = Data(impostor.utf8)
            let (size, body) = MailService.splitSourceSizeMarker(raw)
            XCTAssertNil(size, impostor)
            XCTAssertEqual(body, raw, impostor)
        }
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
