import XCTest
@testable import macmcp

/// The draft `mail_create_draft` asked for, told apart from the copy Mail
/// autosaves behind a compose message's back.
///
/// The hygiene layer separated the two by one header: a deliberate draft has no
/// `X-Apple-Auto-Saved`, an autosave always has one. That held for all 22
/// drafts on the fixture and for every compose that finishes quickly. It does
/// not hold for a slow one.
///
/// Reproduced live on Mail 16.0 against the fixture, with a 300,000-character
/// body and 40 attachments so that compose ran for ~30s: Mail's autosave timer
/// fired while the message was still being built and `mail.save()` then saved
/// **over that same copy**. One message reached Alice's Drafts —
/// `Subject: FIX7-PROBE-slowdraft-6`, `X-Apple-Auto-Saved: 1`,
/// `Message-Id: <A41E17AA-0B21-4D6B-A79A-577C40776312@relaytest.local>` — and
/// the tool reported it twice, once as `draft` (`message_id: 133050`) and once
/// as `autosaved_draft.left_in_drafts: ["133050"]` with a note saying Mail had
/// left a copy behind. One copy on disk, nothing deleted: the report was wrong,
/// not the mailbox.
///
/// So identity, not a header, decides. The draft's own numeric id and RFC
/// Message-ID are already read back off the message by the saved-draft lookup,
/// and either one matching is enough — the numeric id dies when the account
/// re-uploads the draft, and the Message-ID is what survives that.
final class MailComposeOwnDraftTests: XCTestCase {
    /// One account whose Drafts already holds something the user wrote, so a
    /// sweep that simply reported everything in Drafts would be visible.
    private static let account = """
    var mail = makeMail({accounts: [
        {name: 'Alice', emailAddresses: ['alice@relaytest.local'], mailboxes: [
            {name: 'INBOX'},
            {name: 'Drafts', messages: [{id: 500, subject: 'Something the user wrote'}]}
        ]}
    ]});
    """

    /// Reaches the stub's own message constructor through a mailbox that
    /// already exists, so a test can make one arrive *after* the snapshot —
    /// which is what the compose window looks like from the outside.
    private static let makeMessageInto = """
    function makeMessageInto(box, spec) {
        var built = makeMail({accounts: [{name: 'scratch', mailboxes: [
            {name: 'Drafts', messages: [spec]}
        ]}]});
        var m = built.accounts()[0].mailboxes()[0]._msgs[0];
        m._box = box;
        return m;
    }
    """

    /// Runs the hygiene block the way a `mail_create_draft` script does: the
    /// snapshot, then a draft appearing in Drafts, then the sweep, then the
    /// saved-draft lookup's answer being handed to the disown step.
    ///
    /// `savedDraft` is the JSON `savedDraftLookupJXA` produces, or `null` for
    /// a call that could not identify its own draft.
    private func compose(
        subject: String = "Quarterly numbers",
        arrives: (id: Int, rfc: String?, autoSaved: Bool)?,
        savedDraft: String
    ) throws -> [String: Any] {
        let arrival = arrives.map { spec in
            """
            (function() {
                var boxes = mail.accounts()[0].mailboxes();
                for (var b = 0; b < boxes.length; b++) {
                    if (boxes[b]._path !== 'Drafts') continue;
                    boxes[b]._msgs.push(makeMessageInto(boxes[b], {
                        id: \(spec.id),
                        subject: '\(subject)',
                        messageId: \(spec.rfc.map { "'\($0)'" } ?? "null"),
                        autoSaved: \(spec.autoSaved)
                    }));
                }
            })();
            """
        } ?? ""
        return try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.makeMessageInto)
        \(Self.account)
        var msg = {
            sender: function() { return 'alice@relaytest.local'; },
            subject: function() { return '\(subject)'; }
        };
        \(MailService.boundByNameJXA)
        \(MailService.composeDraftHygieneJXA(subject: subject))
        composeObserve();
        \(arrival)
        var result = {};
        result.autosaved_draft = composeSweepDrafts(COMPOSE_SENDER.account, false);
        var savedDraft = \(savedDraft);
        result.draft = savedDraft;
        composeDisownSavedDraft(result.autosaved_draft, savedDraft);
        composeCloseSweep(result.autosaved_draft);
        JSON.stringify({
            report: result.autosaved_draft,
            deleted: mail.log.deleted,
            drafts: (function() {
                var out = [];
                var boxes = mail.accounts()[0].mailboxes();
                for (var i = 0; i < boxes.length; i++) {
                    if (boxes[i]._path !== 'Drafts') continue;
                    var subs = boxes[i].messages.subject();
                    for (var k = 0; k < subs.length; k++) out.push('' + subs[k]);
                }
                return out;
            })()
        });
        """)
    }

    private func report(_ payload: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(payload["report"] as? [String: Any])
    }

    /// The saved-draft lookup's answer for a draft with these identifiers.
    private func saved(id: Int, rfc: String) -> String {
        "{account: 'Alice', mailbox: 'Drafts', message_id: '\(id)', rfc_message_id: '\(rfc)'}"
    }

    // MARK: - The regression

    func testTheDraftThisCallSavedIsNotReportedAsALeakedCopy() throws {
        // Exactly the live shape: one message in Drafts, carrying Mail's
        // autosave header and the Message-Id the call reports as its draft.
        let out = try compose(
            arrives: (id: 133_050, rfc: "A41E17AA@relaytest.local", autoSaved: true),
            savedDraft: saved(id: 133_050, rfc: "A41E17AA@relaytest.local")
        )
        let report = try report(out)
        XCTAssertEqual(
            report["found"] as? Int, 0,
            "the draft the caller asked for was counted as a copy Mail leaked: \(report)"
        )
        XCTAssertNil(
            report["left_in_drafts"],
            "the caller's own draft was named as something left behind: \(report)"
        )
        XCTAssertEqual(
            report["saved_over_autosave"] as? Bool, true,
            "nothing said the save had landed on Mail's autosaved copy: \(report)"
        )
        XCTAssertEqual((out["deleted"] as? [Any])?.count, 0, "something was deleted")
        XCTAssertEqual(
            (out["drafts"] as? [String])?.sorted(),
            ["Quarterly numbers", "Something the user wrote"]
        )
    }

    func testTheRfcMessageIdAloneIsEnoughToRecogniseIt() throws {
        // Mail's numeric id for a freshly saved IMAP draft is short-lived: the
        // account takes the upload and hands back its own copy. The Message-ID
        // survives that, so either handle matching is proof enough.
        let out = try compose(
            arrives: (id: 133_050, rfc: "A41E17AA@relaytest.local", autoSaved: true),
            savedDraft: saved(id: 999_999, rfc: "A41E17AA@relaytest.local")
        )
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 0, "\(report)")
        XCTAssertEqual(report["saved_over_autosave"] as? Bool, true, "\(report)")
    }

    func testTheNumericIdAloneIsEnoughToRecogniseIt() throws {
        // The mirror case: a draft Mail would not give a Message-ID for.
        let out = try compose(
            arrives: (id: 133_050, rfc: nil, autoSaved: true),
            savedDraft: saved(id: 133_050, rfc: "")
        )
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 0, "\(report)")
        XCTAssertEqual(report["saved_over_autosave"] as? Bool, true, "\(report)")
    }

    // MARK: - Controls: a real leak is still a real leak

    func testACopyThatIsNotThisDraftIsStillReported() throws {
        // The thing the sweep exists for. A different id and a different
        // Message-ID from the draft that was saved: two messages in Drafts,
        // one of them Mail's.
        let out = try compose(
            arrives: (id: 900, rfc: "B0B0B0B0@relaytest.local", autoSaved: true),
            savedDraft: saved(id: 133_050, rfc: "A41E17AA@relaytest.local")
        )
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 1, "a leaked copy stopped being reported: \(report)")
        XCTAssertEqual(report["left_in_drafts"] as? [String], ["900"], "\(report)")
        XCTAssertNil(report["saved_over_autosave"], "\(report)")
        XCTAssertTrue(
            (report["note"] as? String)?.contains("still in Drafts") == true,
            "\(report)"
        )
    }

    func testACallThatCouldNotIdentifyItsOwnDraftDisownsNothing() throws {
        // `savedDraft` is null when the lookup could not find the draft. That
        // is not licence to write off whatever is in Drafts as ours.
        let out = try compose(
            arrives: (id: 900, rfc: "B0B0B0B0@relaytest.local", autoSaved: true),
            savedDraft: "null"
        )
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 1, "\(report)")
        XCTAssertEqual(report["left_in_drafts"] as? [String], ["900"], "\(report)")
    }

    func testFindingNothingStillReportsFindingNothing() throws {
        let out = try compose(
            arrives: nil,
            savedDraft: saved(id: 133_050, rfc: "A41E17AA@relaytest.local")
        )
        let report = try report(out)
        XCTAssertEqual(report["checked"] as? Bool, true, "\(report)")
        XCTAssertEqual(report["found"] as? Int, 0, "\(report)")
        XCTAssertNil(report["saved_over_autosave"], "nothing was saved over: \(report)")
        // Finding nothing is a reading taken at a moment, and says so: six
        // sends run while Mail was under load each left a copy whose Date was
        // 7s after the sent message's, after this check had already looked.
        XCTAssertTrue(
            (report["note"] as? String)?.contains("when this was checked") == true,
            "finding nothing was stated as a finished answer: \(report)"
        )
    }

    // MARK: - The report is the report

    func testTheBookkeepingDoesNotReachTheCaller() throws {
        // `held` and `mayRemove` exist so the summary can be rebuilt once the
        // deliberate draft is known. They are not answers to anything.
        let out = try compose(
            arrives: (id: 900, rfc: "B0B0B0B0@relaytest.local", autoSaved: true),
            savedDraft: saved(id: 133_050, rfc: "A41E17AA@relaytest.local")
        )
        let report = try report(out)
        XCTAssertNil(report["held"], "internal bookkeeping was reported: \(report)")
        XCTAssertNil(report["mayRemove"], "internal bookkeeping was reported: \(report)")
    }
}
