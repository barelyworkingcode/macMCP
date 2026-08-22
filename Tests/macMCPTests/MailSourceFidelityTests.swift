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

    func testACRLFThatSurvivedIsNotCountedTwice() {
        // The wire size is the bytes plus one CR for each *bare* LF, because a
        // bare LF is what a CRLF came back as. A CRLF still in the bytes already
        // weighs two, and adding another byte for it inflated the wire size by
        // one per line -- slack in the one direction a completeness guard must
        // never have. Mail strips every CR today, so nothing measured this;
        // `line_endings` reports "crlf" and "mixed" as reachable, and
        // `mail_save_attachment` cuts files out of a message on the strength of
        // `complete`.
        let source = Data("From: a@b.c\r\nSubject: x\r\n\r\nbody\r\n".utf8)
        XCTAssertEqual(source.count, 33)
        let fidelity = MailService.sourceFidelity(source, expectedSize: 33)
        XCTAssertEqual(fidelity.lineEndings, "crlf")
        XCTAssertEqual(fidelity.wireSize, 33, "these bytes are already the wire bytes")
        XCTAssertTrue(fidelity.complete)
    }

    func testAFragmentWithCRLFEndingsIsStillShort() {
        // The consequence of the double count, stated as the caller sees it: 30
        // lines of slack is 30 bytes a fragment could be missing and still be
        // called complete, which is `mail_save_attachment` writing a truncated
        // file and reporting success.
        let line = "0123456789012345678901234567\r\n"  // 30 bytes
        let fragment = Data(String(repeating: line, count: 30).utf8)
        XCTAssertEqual(fragment.count, 900)
        let fidelity = MailService.sourceFidelity(fragment, expectedSize: 930)
        XCTAssertEqual(fidelity.completeBasis, "short")
        XCTAssertFalse(fidelity.complete)
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
        let split = MailService.splitSourceSizeMarker(raw)
        XCTAssertEqual(split.size, 418)
        XCTAssertEqual(split.body, Data("Return-Path: <a@b.c>\nSubject: x\n".utf8))
        XCTAssertNil(split.error)
    }

    func testAMessageMailWouldNotSizeComesBackWithNoSizeAndAllItsBytes() {
        // The script prints -1 when `messageSize` raised. That is "unknown",
        // not "zero bytes", and it is a value macMCP writes itself, so the
        // source comes back whole and only the size is missing.
        var raw = Data("MACMCP-SIZE:-1\n".utf8)
        raw.append(Data("Subject: x\n".utf8))
        let split = MailService.splitSourceSizeMarker(raw)
        XCTAssertNil(split.size)
        XCTAssertEqual(split.body, Data("Subject: x\n".utf8))
        XCTAssertNil(split.error, "-1 is the script's own sentinel, not a broken contract")
    }

    /// The marker is written by `sourceScriptJXA` before a single byte of the
    /// message, unconditionally and on every path, so it is always at offset 0
    /// and the caller's own first line never is. This used to fail *open* on the
    /// reasoning that a first line which merely looks like the marker must not
    /// cost a caller a line of their message — a case that cannot arise — and
    /// what it actually did was leave `MACMCP-SIZE:null` inside the message,
    /// where it reaches `save_to` files, `bytes_total`, `sourceFidelity`'s
    /// counts, and `MIME.parse` as a bogus `macmcp-size:` header (#R3-7).
    func testAValueMacMCPDidNotWriteIsRefusedRatherThanLeftInTheMessage() throws {
        // What `'MACMCP-SIZE:' + expected` prints when `messageSize()` yields
        // something the script did not expect.
        for value in ["null", "NaN", "undefined", "418.5", "", "1-2"] {
            let raw = Data("MACMCP-SIZE:\(value)\nSubject: x\n".utf8)
            let split = MailService.splitSourceSizeMarker(raw)
            XCTAssertNil(split.size, value)
            XCTAssertFalse(
                split.body.starts(with: Data("MACMCP-SIZE:".utf8)),
                "macMCP's own sideband line stayed in the message for \"\(value)\""
            )
            let error = try XCTUnwrap(split.error, "\"\(value)\" was accepted silently")
            XCTAssertTrue(error.contains(value.isEmpty ? "size" : value), error)
        }
    }

    func testOutputWithoutTheMarkerAtAllIsRefused() throws {
        // The script cannot produce this. If it ever does, nothing here can tell
        // macMCP's bytes from the message's, so nothing is returned.
        for impostor in ["X-MACMCP-SIZE:418\nSubject: x\n", "Subject: MACMCP-SIZE:418\n", "MACMCP-SIZE:418"] {
            let split = MailService.splitSourceSizeMarker(Data(impostor.utf8))
            XCTAssertNil(split.size, impostor)
            XCTAssertEqual(split.body, Data(), impostor)
            XCTAssertNotNil(split.error, impostor)
        }
    }

    func testARefusedSizeLineCostsTheCallerAnErrorRatherThanACorruptedMessage() throws {
        // The sentence has to name what happened: "not a number macMCP wrote"
        // is the difference between a bug in the plumbing and something about
        // the message, and only one of the two is worth retrying.
        let split = MailService.splitSourceSizeMarker(Data("MACMCP-SIZE:null\nSubject: x\n".utf8))
        let error = try XCTUnwrap(split.error)
        XCTAssertTrue(error.contains("null"), error)
        XCTAssertTrue(error.contains("-1"), "the accepted sentinel is worth naming: \(error)")
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
            ["complete", "complete_basis", "line_endings", "ambiguous_nul_bytes", "bytes_measured", "message_size"]
        )
        // `complete_basis` is not a second summary. It is not a verdict at all:
        // it names which of the two readings of `messageSize` `complete` rests
        // on, and each of its values is a fact about the bytes rather than a
        // judgement that can only come out one way (#53).
        XCTAssertEqual(dict["complete_basis"] as? String, "bytes")
    }

    // MARK: - What `complete` rests on (#53)

    /// `messageSize` is quoted in one of two units and Mail does not say which:
    /// wire units (CRLFs counted) for a message the server holds, and the units
    /// Mail stores it in for a local draft. Counting every LF as a CRLF is what
    /// makes the first case come out right, and it is exactly what hands the
    /// second one slack.
    func testBytesThatReachTheSizeOnTheirOwnAssumeNothing() {
        // The local-draft shape, measured on the fixture: bytes_measured 1362
        // against message_size 1362, matching the Maildir's S= rather than its
        // W=. This holds whichever unit Mail meant, so there is no slack in it.
        let draft = Data(String(repeating: "x\n", count: 20).utf8)
        let fidelity = MailService.sourceFidelity(draft, expectedSize: draft.count)
        XCTAssertTrue(fidelity.complete)
        XCTAssertEqual(fidelity.completeBasis, "bytes")
        XCTAssertEqual(fidelity.slackBytes, 0)
    }

    func testBytesThatOnlyReachTheSizeAsWireUnitsSayHowMuchSlackThatLeaves() {
        // The server-side shape, and the ordinary case: 375 bytes with 19 line
        // breaks against a reported 394. Right under the wire reading -- but if
        // Mail had meant the other unit, 19 bytes would be missing, and the old
        // `complete: true` said nothing about which.
        let body = Data((String(repeating: "x", count: 356) + String(repeating: "\n", count: 19)).utf8)
        let fidelity = MailService.sourceFidelity(body, expectedSize: 394)
        XCTAssertEqual(fidelity.byteCount, 375)
        XCTAssertTrue(fidelity.complete, "this is what a whole server-side message looks like")
        XCTAssertEqual(fidelity.completeBasis, "wire")
        XCTAssertEqual(fidelity.slackBytes, 19)
        let note = fidelity.note ?? ""
        XCTAssertTrue(note.contains("19 byte(s)"), "the slack is not quantified: \(note)")
    }

    func testAFragmentShortByMoreThanTheLineBreaksIsStillIncomplete() {
        // The direction that was never open, and must not close: a real
        // fragment. Neither reading reaches the size.
        let fragment = Data((String(repeating: "x", count: 100) + String(repeating: "\n", count: 5)).utf8)
        let fidelity = MailService.sourceFidelity(fragment, expectedSize: 394)
        XCTAssertFalse(fidelity.complete)
        XCTAssertEqual(fidelity.completeBasis, "short")
        XCTAssertEqual(fidelity.slackBytes, 0)
    }

    func testTheTwoCasesWithNoSizeToJudgeAgainstAreNamedRatherThanGuessed() {
        XCTAssertEqual(MailService.sourceFidelity(Data("Subject: x\n".utf8), expectedSize: nil).completeBasis, "unchecked")
        XCTAssertEqual(MailService.sourceFidelity(Data(), expectedSize: 400).completeBasis, "none")
        XCTAssertFalse(MailService.sourceFidelity(Data(), expectedSize: 400).complete)
        XCTAssertTrue(MailService.sourceFidelity(Data("Subject: x\n".utf8), expectedSize: nil).complete,
                      "an unreadable size is not evidence the download is unfinished")
    }
}
