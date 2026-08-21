import XCTest
@testable import macmcp

/// The one test that can substantiate anything about `mail_get_source`'s bytes:
/// it compares what the tool returns against a message **file on disk**.
///
/// Everything else in `MailSourceBytesTests` runs its input through
/// `asOsascriptWouldEmit`, which applies the very transform `decodeSourceBytes`
/// inverts. That can only ever prove the function inverts the test's *model* of
/// the pipeline (#23) — and the model was wrong in two places nobody noticed,
/// because a circular test cannot notice them. This one has no model in it.
///
/// ## Running it
///
/// It needs Mail.app, the local `testMail` fixture, and an Automation grant, so
/// it cannot run in CI and skips unless pointed at the fixture:
///
/// ```
/// cd ~/source/barelyworkingcode/testMail && ./testmail.sh start
/// MACMCP_MAIL_FIXTURE=$HOME/source/barelyworkingcode/testMail \
///     swift test --filter MailSourceOnDiskTests
/// ```
///
/// `MACMCP_MAIL_ACCOUNT` (default `Alice`) and `MACMCP_MAIL_USER` (default the
/// lowercased account) select which of the fixture's two accounts to use.
///
/// Skipping is not the same as not existing. A guarantee nothing tests is not a
/// guarantee, and this one — "byte-identical" — has already been wrong twice.
final class MailSourceOnDiskTests: XCTestCase {
    private var fixtureRoot: URL!
    private var account: String!
    private var maildir: URL!
    private var registry: ToolRegistry!
    private var scratch: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MACMCP_MAIL_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("""
            Needs the local mail fixture and a real Mail.app. Start it and point this at it:
              cd ~/source/barelyworkingcode/testMail && ./testmail.sh start
              MACMCP_MAIL_FIXTURE=$HOME/source/barelyworkingcode/testMail swift test --filter MailSourceOnDiskTests
            """)
        }
        fixtureRoot = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        account = ProcessInfo.processInfo.environment["MACMCP_MAIL_ACCOUNT"] ?? "Alice"
        let user = ProcessInfo.processInfo.environment["MACMCP_MAIL_USER"] ?? account.lowercased()
        maildir = fixtureRoot
            .appendingPathComponent("maildirs")
            .appendingPathComponent(user)
            .appendingPathComponent("Maildir")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: maildir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("no Maildir at \(maildir.path) — is the fixture started?")
        }

        registry = ToolRegistry()
        MailService.register(registry)
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-ondisk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - The test

    func testFetchedSourceMatchesTheMessageOnDiskExceptWhereMailChangedIt() throws {
        // Every byte value except CR and LF, carried as 8bit so nothing hides
        // behind base64. CR and LF are left out on purpose: they are line
        // structure, and dovecot is entitled to store them either way, so
        // including them would test the IMAP server rather than Mail.
        let payload = Data((0...255).map(UInt8.init).filter { $0 != 0x0A && $0 != 0x0D })
        XCTAssertEqual(payload.count, 254)

        let subject = "MACMCP-ONDISK-\(UUID().uuidString.prefix(8))"
        let rfcID = "<\(subject.lowercased())@relaytest.local>"
        let message = probeMessage(subject: subject, rfcID: rfcID, payload: payload)
        try deliver(message)

        let onDisk = try XCTUnwrap(
            waitForFileOnDisk(containing: subject),
            "the fixture's IMAP server never picked the message up"
        )
        XCTAssertEqual(onDisk.bytes, message, "the file on disk is not what was delivered")

        try syncMail()
        let numericID = try XCTUnwrap(
            waitForMailToSee(subject: subject),
            "Mail did not show the message within the timeout — its IMAP view can lag the disk by 30s+"
        )
        addTeardownBlock { self.discard(messageID: numericID) }

        // What mail_get_source writes with save_to: the raw bytes, with no
        // JSON string encoding in the way. This is the byte-identity claim's
        // actual surface.
        let saved = scratch.appendingPathComponent("fetched.eml")
        let result = try callJSON("mail_get_source", [
            "message_id": .string(numericID),
            "account": .string(account),
            "mailbox": .string("INBOX"),
            "save_to": .string(saved.path)
        ])
        let fetched = try Data(contentsOf: saved)

        // 1. It is NOT byte-identical, and the two differences are exactly the
        //    ones the tool now reports. Anything else is a real regression.
        let expected = mailsRenderingOf(onDisk.bytes)
        XCTAssertEqual(fetched.count, expected.count)
        XCTAssertEqual(fetched, expected, "a difference beyond Mail's CRLF→LF and NUL→0x80")

        // 2. Stated separately, so the failure names the cause: every CRLF is
        //    gone, and the one NUL came back as 0x80.
        XCTAssertEqual(onDisk.bytes.filter { $0 == 0x0D }.count, 21, "the delivered message's CRLF count")
        XCTAssertFalse(fetched.contains(0x0D), "Mail returned CRLF after all — the fidelity report is now wrong")
        XCTAssertEqual(onDisk.bytes.filter { $0 == 0x00 }.count, 1)
        XCTAssertFalse(fetched.contains(0x00), "Mail preserved a NUL — the fidelity report is now wrong")

        // 3. Everything else does round-trip. This is the part of #5's claim
        //    that holds, and it is worth keeping honest: 253 of the 254 byte
        //    values in the payload come back untouched.
        let attachment = try XCTUnwrap(MIME.attachments(of: MIME.parse(fetched)).first)
        XCTAssertEqual(attachment.data.count, payload.count)
        XCTAssertEqual(attachment.data.dropFirst(), payload.dropFirst(), "a byte other than the NUL was altered")
        XCTAssertEqual(attachment.data.first, 0x80)

        // 4. The caller is told, in the response rather than in a code comment.
        let fidelity = try XCTUnwrap(result["fidelity"] as? [String: Any])
        XCTAssertEqual(fidelity["line_endings"] as? String, "lf")
        XCTAssertEqual(fidelity["bytes_measured"] as? Int, fetched.count)
        // Two: the probe's own 0x80, and the NUL that became one. Both stand
        // alone -- the payload runs 0x00 to 0xFF in order, so neither sits in a
        // UTF-8 continuation position -- which is what makes them candidates.
        // Counting *every* 0x80 would agree here by luck and disagree on any
        // message containing an em dash.
        XCTAssertEqual(fidelity["ambiguous_nul_bytes"] as? Int, 2)
        XCTAssertEqual(fetched.filter { $0 == 0x80 }.count, 2, "the bytes the count is about")
        let note = try XCTUnwrap(fidelity["note"] as? String)
        XCTAssertTrue(note.contains("CRLF"), note)
        XCTAssertTrue(note.contains("0x80"), note)

        // 5. The whole message arrived, and Mail's own idea of its size agrees
        //    with the bytes that were delivered. This is what caught #31: the
        //    fetch used to return whatever Mail had downloaded so far.
        XCTAssertEqual(fidelity["complete"] as? Bool, true)
        XCTAssertEqual(
            fidelity["message_size"] as? Int,
            onDisk.bytes.count,
            "Mail's messageSize disagrees with the bytes that were delivered"
        )
    }

    /// What this can establish about #31, and what it cannot.
    ///
    /// It was called `testAMessageStillArrivingIsWaitedForRatherThanReturnedInPieces`
    /// and could not fail for that property: setting `sourceCompletionAttempts`
    /// to 0 — removing the wait entirely — left it passing, because
    /// `waitForMailToSee` polls `mail_get_emails` for up to two minutes first
    /// and Mail has finished downloading long before the fetch is made. Over
    /// loopback the window is sub-second; it can be widened by throttling a
    /// clone of the fixture's IMAPS proxy and severing it, but a test cannot
    /// arrange that for itself, and one that pretends to is worse than one that
    /// says what it covers.
    ///
    /// **The wait itself is exercised hermetically** by
    /// `MailSourceScriptTests.testAMessageStillDownloadingIsWaitedForRatherThanReturnedInPieces`,
    /// which runs the generated script against a stub whose `source()` grows
    /// between calls: remove the loop and it fails on both the bytes and the
    /// read count.
    ///
    /// What only a live message can establish is the **premise** that wait rests
    /// on, which the stub encodes rather than tests: that Mail's `messageSize`
    /// is the message's *wire* size, so `source.count + LF count == messageSize`
    /// is an exact comparison rather than a heuristic. If that were ever a
    /// different quantity — the size of the local partial, say — the check would
    /// pass on a fragment and nothing else would notice.
    func testMailsMessageSizeIsTheWireSizeTheCompletenessCheckComparesAgainst() throws {
        // 300 KB, the size at which the original fragment was measured.
        let payload = Data((0..<300_000).map { UInt8(($0 * 13 + 7) % 256) })
            .map { $0 == 0x0A || $0 == 0x0D ? 0x2E : $0 }
        let subject = "MACMCP-BIG-\(UUID().uuidString.prefix(8))"
        let rfcID = "<\(subject.lowercased())@relaytest.local>"
        let message = probeMessage(subject: subject, rfcID: rfcID, payload: Data(payload))
        try deliver(message)
        _ = try XCTUnwrap(waitForFileOnDisk(containing: subject), "the fixture never took the message")

        try syncMail()
        let numericID = try XCTUnwrap(waitForMailToSee(subject: subject), "Mail did not show the message")
        addTeardownBlock { self.discard(messageID: numericID) }

        let saved = scratch.appendingPathComponent("big.eml")
        let result = try callJSON("mail_get_source", [
            "message_id": .string(numericID),
            "account": .string(account),
            "mailbox": .string("INBOX"),
            "save_to": .string(saved.path)
        ])
        let fetched = try Data(contentsOf: saved)

        // The message that was read is the message that was delivered. Every
        // number below is meaningless if the id resolved to something else, and
        // a numeric id comes from a separate column fetch than the subject it
        // was chosen by.
        XCTAssertTrue(
            String(decoding: fetched.prefix(2048), as: UTF8.self).contains(rfcID),
            "mail_get_source returned a different message than the one that was delivered"
        )

        let fidelity = try XCTUnwrap(result["fidelity"] as? [String: Any])
        XCTAssertEqual(
            fidelity["message_size"] as? Int,
            message.count,
            "Mail's messageSize is not the wire size of the delivered bytes, which is what the completeness check compares against"
        )
        // The comparison the fetch makes, done here against the bytes on the
        // wire: one CR back for every LF.
        XCTAssertEqual(
            fetched.count + fetched.filter { $0 == 0x0A }.count,
            message.count,
            "the LF-for-CRLF arithmetic does not add up on a real message"
        )
        XCTAssertEqual(fidelity["complete"] as? Bool, true, "a message Mail has in full was reported as a fragment")
        XCTAssertEqual(fidelity["bytes_measured"] as? Int, fetched.count)
    }

    // MARK: - Building and delivering the probe

    private func probeMessage(subject: String, rfcID: String, payload: Data) -> Data {
        var message = Data(([
            "Return-Path: <archivist@relaytest.local>",
            "From: Byte Probe <archivist@relaytest.local>",
            "To: \(account!) Tester <\(account.lowercased())@relaytest.local>",
            "Subject: \(subject)",
            "Message-ID: \(rfcID)",
            "Date: Fri, 21 Aug 2026 19:30:00 +0000",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"BYTEBOUND\"",
            "", ""
        ] as [String]).joined(separator: "\r\n").utf8)
        message.append(Data("""
        --BYTEBOUND\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        plain part\r

        """.utf8))
        message.append(Data("""
        --BYTEBOUND\r
        Content-Type: application/octet-stream; name="raw.bin"\r
        Content-Disposition: attachment; filename="raw.bin"\r
        Content-Transfer-Encoding: 8bit\r
        \r

        """.utf8))
        message.append(payload)
        message.append(Data("\r\n--BYTEBOUND--\r\n".utf8))
        return message
    }

    /// Writes the message into `Maildir/new` the way an MDA would: into `tmp`
    /// first, then rename, so dovecot never sees a half-written file.
    private func deliver(_ message: Data) throws {
        let name = "\(Int(Date().timeIntervalSince1970)).M\(getpid())Q\(Int.random(in: 1...9999)).macmcptest"
        let tmp = maildir.appendingPathComponent("tmp").appendingPathComponent(name)
        try message.write(to: tmp)
        try FileManager.default.moveItem(
            at: tmp,
            to: maildir.appendingPathComponent("new").appendingPathComponent(name)
        )
    }

    /// dovecot moves the file from `new` to `cur` and renames it, so it is
    /// found by content rather than by the name it was written under.
    private func waitForFileOnDisk(containing subject: String) -> (url: URL, bytes: Data)? {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            for directory in ["new", "cur"] {
                let dir = maildir.appendingPathComponent(directory)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                for name in names {
                    let url = dir.appendingPathComponent(name)
                    guard let bytes = try? Data(contentsOf: url),
                          let text = String(data: bytes.prefix(2048), encoding: .isoLatin1),
                          text.contains(subject) else { continue }
                    return (url, bytes)
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    // MARK: - Talking to Mail

    /// Mail's IMAP view lags the disk, by 30s or more in the fixture's own
    /// notes, so it is asked to look and then given time to.
    private func syncMail() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Mail\" to check for new mail"]
        try process.run()
        process.waitUntilExit()
    }

    private func waitForMailToSee(subject: String) throws -> String? {
        let deadline = Date().addingTimeInterval(120)
        repeat {
            let payload = try callJSON("mail_get_emails", [
                "account": .string(account),
                "mailbox": .string("INBOX"),
                "limit": .int(50)
            ])
            let messages = payload["messages"] as? [[String: Any]] ?? []
            if let hit = messages.first(where: { $0["subject"] as? String == subject }),
               let id = hit["id"] as? String {
                return id
            }
            Thread.sleep(forTimeInterval: 3)
        } while Date() < deadline
        return nil
    }

    /// Leaves the fixture as it was found: the probe goes to Trash rather than
    /// sitting in an INBOX later runs and humans have to look at.
    private func discard(messageID: String) {
        _ = registry.call(name: "mail_move", arguments: [
            "message_id": .string(messageID),
            "account": .string(account),
            "source_mailbox": .string("INBOX"),
            "target_mailbox": .string("Trash")
        ])
    }

    private func callJSON(_ name: String, _ arguments: JSONObject) throws -> [String: Any] {
        let result = registry.call(name: name, arguments: arguments)
        let text = result.content.first?.text ?? ""
        if result.isError == true { throw Failure(message: "\(name) failed: \(text)") }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "\(name) did not return a JSON object: \(text)")
        }
        return object
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The two things Mail does to a message before macMCP ever sees it,
    /// measured rather than assumed: CRLF becomes LF, and a NUL becomes 0x80.
    private func mailsRenderingOf(_ message: Data) -> Data {
        var out = Data()
        var previous: UInt8 = 0
        for byte in message {
            if previous == 0x0D && byte != 0x0A { out.append(0x0D) }
            switch byte {
            case 0x00: out.append(0x80)
            case 0x0D: break
            default: out.append(byte)
            }
            previous = byte
        }
        if previous == 0x0D { out.append(0x0D) }
        return out
    }
}
