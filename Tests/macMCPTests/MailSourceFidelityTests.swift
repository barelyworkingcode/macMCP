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

    func testACrlfSourceIsNotWarnedAboutItsLineEndings() {
        // Synthetic: Mail strips every CR, so this is what a future Mail that
        // stopped doing so would produce. `expectedSize` is supplied because a
        // size Mail would not report is itself worth a sentence.
        let fidelity = MailService.sourceFidelity(Data("Subject: x\r\n\r\nbody\r\n".utf8), expectedSize: 20)
        XCTAssertEqual(fidelity.lineEndings, "crlf")
        XCTAssertTrue(fidelity.complete)
        XCTAssertEqual(fidelity.ambiguousNulBytes, 0)
        XCTAssertNil(fidelity.note, "nothing is wrong with these bytes, so there is nothing to say")
    }

    func testAnLfSourceIsNotClaimedToBeExact() {
        // What Mail actually returns for every message: 21 CRLFs on disk came
        // back as 21 LFs. A caller comparing against the server's copy needs to
        // know before, not after.
        let fidelity = MailService.sourceFidelity(Data("Subject: x\n\nbody\n".utf8), expectedSize: 20)
        XCTAssertEqual(fidelity.lineEndings, "lf")
        XCTAssertTrue(try XCTUnwrap(fidelity.note).contains("CRLF"), fidelity.note ?? "")
    }

    func testMixedLineEndingsAreNotPassedOffAsEither() throws {
        let fidelity = MailService.sourceFidelity(Data("a\r\nb\nc\r\n".utf8), expectedSize: 10)
        XCTAssertEqual(fidelity.lineEndings, "mixed")
        XCTAssertTrue(try XCTUnwrap(fidelity.note).contains("CRLF"), fidelity.note ?? "")
    }

    func testABareCarriageReturnCountsAsMixedRatherThanCrlf() {
        // A lone CR is not a line ending Mail produces, so it must not be
        // reported as the clean case.
        XCTAssertEqual(MailService.sourceFidelity(Data("a\rb".utf8)).lineEndings, "mixed")
        XCTAssertEqual(MailService.sourceFidelity(Data("a\r\nb\r".utf8)).lineEndings, "mixed")
    }

    func testDataWithNoLineBreaksIsNotAccusedOfAnything() {
        let fidelity = MailService.sourceFidelity(Data("Subject: x".utf8), expectedSize: 10)
        XCTAssertEqual(fidelity.lineEndings, "none")
        XCTAssertNil(fidelity.note)
    }

    // MARK: - The NUL, which is ambiguous rather than merely lost

    func testAStandalone0x80IsCountedAsAPossibleLostNul() throws {
        // 0x80 is where a NUL lands. It is also a perfectly ordinary byte, and
        // nothing after the fact can say which one a given 0x80 was -- so the
        // count is reported and the ambiguity is stated, rather than either
        // being guessed at.
        let fidelity = MailService.sourceFidelity(Data([0x41, 0x80, 0x42, 0x80, 0x0D, 0x0A]))
        XCTAssertEqual(fidelity.ambiguousNulBytes, 2)
        let note = try XCTUnwrap(fidelity.note)
        XCTAssertTrue(note.contains("2 byte(s)"), note)
        XCTAssertTrue(note.contains("indistinguishable"), note)
    }

    func testA0x80InsideAUTF8CharacterIsNotAPossibleLostNul() {
        // The reported case: a body of ordinary typography. Three em dashes
        // (E2 80 94) and one Hebrew word, no NUL and no standalone 0x80
        // anywhere -- and `ambiguous_nul_bytes: 3` with the whole NUL paragraph
        // attached. Mail replaces a NUL with a lone 0x80; a 0x80 that completes
        // a valid character cannot be one.
        let body = Data("em dash — here — and Hebrew שלום — end".utf8)
        XCTAssertEqual(body.filter { $0 == 0x80 }.count, 3, "the bytes the old count was looking at")
        XCTAssertFalse(body.contains(0x00))
        let fidelity = MailService.sourceFidelity(body)
        XCTAssertEqual(fidelity.ambiguousNulBytes, 0)
        XCTAssertFalse(try XCTUnwrap(fidelity.note).contains("0x80"), "an em dash was reported as a lost NUL")
    }

    func testALost0x80NextToUTF8TextIsStillCounted() {
        // The em dash must not become cover for the case that matters: a NUL
        // that landed right beside one.
        var data = Data("dash — ".utf8)
        data.append(0x80)
        data.append(Data(" end".utf8))
        XCTAssertEqual(MailService.sourceFidelity(data).ambiguousNulBytes, 1)
    }

    func testBytesThatOnlyLookLikeUTF8AreNotStumbledOver() {
        // A source is raw RFC 822, not text: a truncated or invalid sequence
        // must not swallow the byte after it. E2 80 with no third byte is not
        // an em dash, so its 0x80 stands alone and counts.
        XCTAssertEqual(MailService.sourceFidelity(Data([0xE2, 0x80])).ambiguousNulBytes, 1)
        // C0 80 is the overlong encoding of NUL, which is not valid UTF-8.
        XCTAssertEqual(MailService.sourceFidelity(Data([0xC0, 0x80])).ambiguousNulBytes, 1)
        // A lead byte whose sequence is well formed does hide its continuation
        // bytes, which under-counts rather than over-counts. Stated so the
        // trade-off is visible rather than discovered.
        XCTAssertEqual(MailService.sourceFidelity(Data([0xE2, 0x80, 0x94])).ambiguousNulBytes, 0)
    }

    func testASourceWithNo0x80IsNotWarnedAbout() {
        let fidelity = MailService.sourceFidelity(Data("Subject: plain\r\n".utf8), expectedSize: 16)
        XCTAssertEqual(fidelity.ambiguousNulBytes, 0)
        XCTAssertNil(fidelity.note)
    }

    func testAnActualNulIsNotCountedAsItsOwnReplacement() {
        // If a future Mail stops destroying NULs, the bytes arrive with 0x00 in
        // them and there is nothing ambiguous left to report.
        let fidelity = MailService.sourceFidelity(Data([0x41, 0x00, 0x42, 0x0D, 0x0A]), expectedSize: 5)
        XCTAssertEqual(fidelity.ambiguousNulBytes, 0)
        XCTAssertNil(fidelity.note)
    }

    // MARK: - A message Mail has not finished downloading (#31)

    func testASourceShorterThanTheMessageIsReportedAsIncomplete() throws {
        // 838 bytes of a 300 KB message, which is what `source()` returns while
        // Mail is still fetching. Nothing in the old response distinguished that
        // from an 838-byte message.
        let fragment = Data(repeating: 0x41, count: 800) + Data("\n".utf8)
        let fidelity = MailService.sourceFidelity(fragment, expectedSize: 300_511)
        XCTAssertFalse(fidelity.complete)
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

    func testASourceMailCannotSizeIsNotAccusedOfBeingIncomplete() throws {
        // `messageSize` failing is not evidence of anything, and reporting a
        // guess as a fact is what this whole seam exists to stop. But it is not
        // a verified match either, and the caller has to be able to tell the
        // two apart (#39): `message_size` is null rather than absent, and the
        // note says what `complete` is worth here.
        let fidelity = MailService.sourceFidelity(Data("Subject: x\r\n".utf8), expectedSize: nil)
        XCTAssertTrue(fidelity.complete)
        XCTAssertFalse(fidelity.sizeKnown)
        XCTAssertTrue(fidelity.dict["message_size"] is NSNull)
        XCTAssertNil(fidelity.dict["message_size"] as? Int)
        XCTAssertTrue(try XCTUnwrap(fidelity.note).contains("would not report this message's size"), fidelity.note ?? "")
    }

    func testAnEmptySourceIsNeverComplete() throws {
        // Zero bytes is the one call that needs no size: every RFC 822 message
        // has a header block, so an empty source is the absence of a message.
        // It used to come back `complete: true` whenever `messageSize` was also
        // unreadable -- the two failures a stalled download produces together.
        for expected in [nil, 400_000] as [Int?] {
            let fidelity = MailService.sourceFidelity(Data(), expectedSize: expected)
            XCTAssertFalse(fidelity.complete, "expectedSize: \(String(describing: expected))")
            XCTAssertTrue(try XCTUnwrap(fidelity.note).contains("no bytes at all"), fidelity.note ?? "")
        }
    }

    func testCompletenessIsReportedEvenWhenNothingElseIsWrong() {
        let dict = MailService.sourceFidelity(Data("Subject: x\r\n".utf8), expectedSize: 12).dict
        XCTAssertEqual(dict["complete"] as? Bool, true)
        XCTAssertEqual(dict["message_size"] as? Int, 12)
    }

    // MARK: - What the numbers are measured over (#36)

    func testTheCountsSayHowManyBytesTheyWereMeasuredOver() throws {
        // `mail_get_source` measures fidelity over the whole source and returns
        // only max_bytes of it, so a caller asking for 80 bytes of ASCII headers
        // was told "3 byte(s) here are 0x80" about bytes that were not there.
        // The measurement stays whole-source -- the caveats are properties of
        // the message, not of the slice -- and now says so.
        var data = Data("Subject: x\n".utf8)
        data.append(0x80)
        let dict = MailService.sourceFidelity(data, expectedSize: 13).dict
        XCTAssertEqual(dict["bytes_measured"] as? Int, data.count)
        let note = try XCTUnwrap(dict["note"] as? String)
        XCTAssertTrue(note.contains("across all \(data.count) bytes"), note)
        XCTAssertFalse(note.contains("byte(s) here"), "\"here\" is not where they were counted: \(note)")
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
        let dict = MailService.sourceFidelity(Data([0x41, 0x80, 0x0A, 0x42, 0x0A]), expectedSize: 7).dict
        XCTAssertEqual(dict["line_endings"] as? String, "lf")
        XCTAssertEqual(dict["ambiguous_nul_bytes"] as? Int, 1)
        let note = try XCTUnwrap(dict["note"] as? String)
        XCTAssertTrue(note.contains("CRLF"), note)
        XCTAssertTrue(note.contains("0x80"), note)
    }

    func testAResultWithNothingToReportCarriesNoNote() {
        let dict = MailService.sourceFidelity(Data("Subject: x\r\n".utf8), expectedSize: 12).dict
        XCTAssertNil(dict["note"])
    }

    func testNoSummaryBooleanIsOffered(  ) {
        // `exact` was `complete && crlf && no 0x80`. Mail strips every CR, so it
        // was false for every real message -- including one whose bytes matched
        // the copy on disk exactly -- and true only for data the pipeline cannot
        // produce. A field that cannot be true is not a field (#37).
        let dict = MailService.sourceFidelity(Data("Subject: x\r\n".utf8), expectedSize: 12).dict
        XCTAssertNil(dict["exact"])
        XCTAssertEqual(
            Set(dict.keys),
            ["complete", "line_endings", "ambiguous_nul_bytes", "bytes_measured", "message_size"]
        )
    }
}
