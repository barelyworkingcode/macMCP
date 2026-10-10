import XCTest
@testable import macmcp

/// End-to-end `mail_send` from a profile that names neither Drafts nor Sent.
///
/// Sends real mail through Mail.app, but only ever to the loopback `testMail`
/// fixture (`.local` recipients on a mail system that cannot deliver off the
/// machine). CI and any host without the fixture skip.
///
/// ```
/// cd ~/source/barelyworkingcode/testMail && ./testmail.sh start
/// MACMCP_MAIL_FIXTURE=$HOME/source/barelyworkingcode/testMail \
///     swift test --filter MailSendFixtureTests
/// ```
///
/// `MACMCP_MAIL_ACCOUNT` (default `Alice`) is the sender; `MACMCP_MAIL_RECIPIENT`
/// (default `bob`) is the recipient's fixture user. The test passes only when
/// the message file appears in the recipient's Maildir, so a send that is
/// merely reported cannot pass.
final class MailSendFixtureTests: XCTestCase {
    private var account: String!
    private var recipient: String!
    private var recipientMaildir: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MACMCP_MAIL_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("""
            Needs the local mail fixture and a real Mail.app. Start it and point this at it:
              cd ~/source/barelyworkingcode/testMail && ./testmail.sh start
              MACMCP_MAIL_FIXTURE=$HOME/source/barelyworkingcode/testMail swift test --filter MailSendFixtureTests
            """)
        }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        account = ProcessInfo.processInfo.environment["MACMCP_MAIL_ACCOUNT"] ?? "Alice"
        recipient = ProcessInfo.processInfo.environment["MACMCP_MAIL_RECIPIENT"] ?? "bob"
        recipientMaildir = root
            .appendingPathComponent("maildirs")
            .appendingPathComponent(recipient)
            .appendingPathComponent("Maildir")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recipientMaildir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("no Maildir at \(recipientMaildir.path) — is the fixture started?")
        }
    }

    func testMailSendFromADraftsLessProfileIsDelivered() throws {
        let registry = ToolRegistry()
        MailService.register(registry)
        let marker = "MACMCP-SEND-\(UUID().uuidString.prefix(8))"
        let result = registry.call(
            name: "mail_send",
            arguments: [
                "to": .string("\(recipient!)@relaytest.local"),
                "subject": .string(marker),
                "body": .string("probe")
            ],
            meta: [
                "mail_accounts": .array([.string(account)]),
                "mail_mailboxes": .array([.string("Archive"), .string("INBOX")])
            ]
        )
        let text = result.content.first?.text ?? ""
        XCTAssertNil(result.meta?["scope_violation"], text)
        XCTAssertNotEqual(result.isError, true, text)
        XCTAssertTrue(text.contains("sent"), text)

        XCTAssertTrue(waitForDelivery(containing: marker), "\(marker) never reached \(recipient!)'s Maildir")
    }

    /// Bounded failure guard only: returns as soon as the file appears.
    private func waitForDelivery(containing marker: String) -> Bool {
        let deadline = Date().addingTimeInterval(60)
        repeat {
            for directory in ["new", "cur"] {
                let dir = recipientMaildir.appendingPathComponent(directory)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                for name in names {
                    guard let bytes = try? Data(contentsOf: dir.appendingPathComponent(name)),
                          let body = String(data: bytes.prefix(4096), encoding: .isoLatin1),
                          body.contains(marker) else { continue }
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }
}
