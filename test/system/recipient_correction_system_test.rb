require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class RecipientCorrectionSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 1000)
  end

  test "editing a lead corrects saved and stale formatted envelopes without changing history or alternates" do
    lead = Lead.create!(name: "Alice Recipient", email: "wrong@example.test", source: "manual")
    original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Already queued" })
    original.conversation.create_draft!(owner: lead, to_addrs: lead.email, cc_addrs: lead.email,
      bcc_addrs: lead.email, subject: "Trip details", body: "Saved words")
    visit edit_lead_path(lead)
    fill_in "Primary email", with: "correct@example.test"
    click_button "Save changes"
    assert_selector "h1", text: lead.name
    envelope
    assert_field "To", with: "correct@example.test"
    find("summary", text: "Cc / Bcc", exact_text: true).click
    assert_field "Cc", with: "correct@example.test"
    assert_field "Bcc", with: "correct@example.test"
    capture("corrected-draft")
    browser_request(lead_messages_path(lead), "POST", conversation_id: original.conversation_id,
      message: { to: "Alice <wrong@example.test>, alternate@example.test",
        cc: "Alice <WRONG@example.test>", bcc: "Alice <wrong@example.test>", subject: "Stale form", body: "Saved words" })
    outgoing = Message.order(:id).last
    assert_equal "correct@example.test, alternate@example.test", outgoing.to_addrs
    assert_equal "correct@example.test", outgoing.cc_addrs
    assert_equal "correct@example.test", outgoing.bcc_addrs
    assert_equal "wrong@example.test", original.reload.to_addrs
    assert_equal "queued", original.status
    record("corrected-envelope", outgoing.slice(:to_addrs, :cc_addrs, :bcc_addrs, :status).merge("historical_to" => original.to_addrs))
  end

  test "malformed draft can reopen on record and inbox then be repaired and sent" do
    lead = Lead.create!(name: "Alice Draft", email: "alice@example.test", source: "manual")
    original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Original" })
    visit lead_path(lead)
    envelope
    fill_in "To", with: "Alice <alice@example.test"
    fill_in "Subject", with: "Unfinished draft"
    fill_in "message_body", with: "Words to keep"
    click_button "Save draft"
    [ lead_path(lead), inbox_thread_path(original.conversation) ].each do |path|
      visit path
      envelope
      assert_field "To", with: "Alice <alice@example.test"
      assert_field "message_body", with: "Words to keep"
    end
    count = Message.count
    click_button "Send", exact: true
    assert_text "Enter valid recipient email addresses"
    assert_equal count, Message.count
    envelope
    assert_field "To", with: "Alice <alice@example.test"
    capture("malformed-draft-editable")
    fill_in "To", with: "Alice <alice@example.test>"
    click_button "Send", exact: true
    assert_text "Sending your reply"
    assert_equal count + 1, Message.count
    assert_equal "alice@example.test", Message.order(:id).last.to_addrs
  end

  [ false, true ].each do |existing|
    test "simultaneous reassignment and conversion to #{existing ? 'existing' : 'new'} client requires confirmation" do
      lead = Lead.create!(name: "Traveler party", email: "owner@example.test", source: "manual")
      one = lead.people.create!(name: "One", email: "a@example.test")
      two = lead.people.create!(name: "Two", email: "b@example.test")
      original = Outbound::Composer.call(owner: lead, params: { to: one.email, body: "Queued for One" })
      original.conversation.create_draft!(owner: lead, to_addrs: one.email, subject: "For One", body: "Unsent words")
      client = Client.create!(name: "Returning party", email: lead.email) if existing
      browser_request(lead_path(lead), "PATCH", lead: { people_attributes: {
        "0" => { id: one.id, name: one.name, email: "b@example.test" },
        "1" => { id: two.id, name: two.name, email: "c@example.test" }
      } })
      browser_request(convert_lead_path(lead), "POST", expected_client_id: client&.id || "new")
      client = lead.reload.converted_client
      assert_not_nil client
      count = Message.count
      response = browser_request(client_messages_path(client), "POST", conversation_id: original.conversation_id,
        message: { to: "a@example.test", subject: "For One", body: "Unsent words" })
      assert_includes response["body"], "confirm the current recipients"
      assert_equal count, Message.count
      visit client_path(client)
      envelope
      assert_field "To", with: "b@example.test"
      assert_text "One: b@example.test"
      assert_text "Two: c@example.test"
      capture("conversion-confirmation-#{existing}")
      check "I confirm these are the intended current recipients."
      click_button "Send", exact: true
      assert_text "Sending your reply"
      assert_equal count + 1, Message.count
      assert_equal "b@example.test", Message.order(:id).last.to_addrs
      assert_equal "a@example.test", original.reload.to_addrs
      assert_equal "queued", original.status
    end
  end

  test "group preview rejects unconfirmed restored recipients atomically and accepts fresh confirmation" do
    lead = Lead.create!(name: "Restored traveler", email: "restored@example.test", source: "manual")
    template = Template.create!(name: "Live group", purpose: "custom", subject: "Hello", body: "Travel update")
    browser_request(lead_path(lead), "PATCH", lead: { email: "" })
    browser_request(lead_path(lead), "PATCH", lead: { email: "restored@example.test" })
    visit merge_templates_path(template_id: template.id)
    fill_in "Recipients", with: "alternate@example.test\nRestored <restored@example.test>"
    tolerate_submit_navigation { click_button "Preview merge" }
    tolerate_navigation_assertion { assert_text "2 messages ready" }
    assert_unchecked_field "I confirm the listed recipients for Restored traveler."
    capture("group-confirmation")
    count = Message.count
    tolerate_submit_navigation { click_button "Send 2 personal emails" }
    tolerate_navigation_assertion { assert_text "confirm the current recipients" }
    assert_equal count, Message.count
    assert_equal 0, GroupSend.count
    tolerate_submit_navigation { click_button "Preview merge" }
    check "I confirm the listed recipients for Restored traveler."
    tolerate_submit_navigation { click_button "Send 2 personal emails" }
    tolerate_navigation_assertion { assert_selector "h1", text: "Send summary" }
    assert_equal count + 2, Message.count
    assert_equal [ "alternate@example.test", "restored@example.test" ], GroupSend.last.messages.order(:id).map(&:to_addrs)
    capture("group-send-summary")
  end

  test "stale group preview delivers corrected traveler booking context and reply cannot borrow another owner history" do
    lead = Lead.create!(name: "Intended Traveler", email: "wrong@example.test", source: "manual", perfectbook_contact_id: 8202)
    [ [ 8201, "Other Traveler", "wrong@example.test", "OTHER-PRIVATE" ],
      [ 8202, "Intended Traveler", "correct@example.test", "INTENDED-TREK" ] ].each do |id, name, email, trip|
      PerfectBook::Contact.create!(perfectbook_id: id, name: name, email: email, synced_at: Time.current)
      PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: id, trip_name: trip, synced_at: Time.current)
    end
    template = Template.create!(name: "Booking update", purpose: "custom", subject: "Trip for {{full_name}}", body: "{{full_name}}: {{trip}}")
    visit merge_templates_path(template_id: template.id)
    fill_in "Recipients", with: "wrong@example.test"
    tolerate_submit_navigation { click_button "Preview merge" }
    tolerate_navigation_assertion { assert_text "1 message ready" }
    browser_request(lead_path(lead), "PATCH", lead: { email: "correct@example.test" })
    tolerate_submit_navigation { click_button "Send 1 personal emails" }
    tolerate_navigation_assertion { assert_selector "h1", text: "Send summary" }
    message = GroupSend.last.messages.last
    assert_equal "correct@example.test", message.to_addrs
    assert_includes message.text_body, "INTENDED-TREK"
    assert_not_includes message.text_body, "OTHER-PRIVATE"
    record("group-corrected-identity", message.slice(:to_addrs, :subject, :text_body))

    unrelated = Lead.create!(name: "Unrelated", email: "unrelated@example.test", source: "manual")
    # Remove the independent mirror at the old address so it cannot legitimately supply context.
    PerfectBook::Contact.find_by!(perfectbook_id: 8201).destroy!
    response = browser_request(reply_context_templates_path(owner_type: "Lead", owner_id: unrelated.id, to: "wrong@example.test"), "GET")
    context = JSON.parse(response["body"])
    assert_empty context["bookings"]
    assert_nil context["context"]["trip"]
    assert_not_includes response["body"], "INTENDED-TREK"
    record("unrelated-reply-context", context)
  end

  test "old drafts survive twenty two corrections and a cleared contact cannot redirect to a new person" do
    lead = Lead.create!(name: "History traveler", email: "first@example.test", source: "manual")
    22.times do |index|
      browser_request(lead_path(lead), "PATCH", lead: { email: "correction-#{index}@example.test" })
    end
    browser_request(lead_messages_path(lead), "POST", message: { to: "first@example.test", subject: "Old draft", body: "Still for same traveler" })
    assert_equal "correction-21@example.test", Message.order(:id).last.to_addrs
    person = lead.people.create!(name: "Cleared", email: "cleared@example.test")
    browser_request(lead_path(lead), "PATCH", lead: { people_attributes: { "0" => { id: person.id, name: person.name, email: "" } } })
    assert_nil person.reload.email
    browser_request(lead_path(lead), "PATCH", lead: { people_attributes: { "0" => { name: "New person", email: "new-person@example.test" } } })
    count = Message.count
    browser_request(lead_messages_path(lead), "POST", message: { to: "cleared@example.test", subject: "Stale", body: "Not for new person" })
    assert_equal count, Message.count
    record("long-history-and-clearing", { corrected_to: Message.order(:id).last.to_addrs, rejected_cleared_recipient: true, messages_before: count, messages_after: Message.count })
  end

  test "later reassignment edits and stale confirmations cannot silently select a traveler" do
    lead = Lead.create!(name: "Reassignment guard", email: "owner@example.test", source: "manual")
    one = lead.people.create!(name: "One", email: "reused@example.test")
    browser_request(lead_path(lead), "PATCH", lead: { people_attributes: {
      "0" => { id: one.id, email: "one@example.test" },
      "1" => { name: "Two", email: "reused@example.test" }
    } })
    visit lead_path(lead)
    token = find("input[type=checkbox][name='message[recipient_confirmation]']", visible: :all).value
    count = Message.count
    %w[to cc bcc].each do |field|
      response = browser_request(lead_messages_path(lead), "POST", message: {
        to: "alternate@example.test", field => "Two <reused@example.test>", subject: "Stale", body: "For review", recipient_confirmation: "1"
      })
      assert_includes response["body"], "confirm the current recipients"
      assert_equal count, Message.count
    end
    two = lead.people.find_by!(name: "Two")
    browser_request(lead_path(lead), "PATCH", lead: { people_attributes: { "0" => { id: two.id, email: "two@example.test" } } })
    response = browser_request(lead_messages_path(lead), "POST", message: {
      to: "One <reused@example.test>", subject: "Stale", body: "For One", recipient_confirmation: token
    })
    assert_includes response["body"], "Choose a current recipient"
    assert_equal count, Message.count
    browser_request(lead_messages_path(lead), "POST", message: {
      to: "one@example.test", subject: "Selected One", body: "For One"
    })
    assert_equal "one@example.test", Message.order(:id).last.to_addrs
    record("persistent-ambiguity", { rejected_formatted_fields: %w[to cc bcc], rejected_old_confirmation: true, deliberate_current_recipient: Message.order(:id).last.to_addrs })
  end

  test "group refuses conflicting owners and restored destinations reject stale confirmation" do
    lead = Lead.create!(name: "Cycle traveler", email: "a@example.test", source: "manual")
    %w[b c a].each { |email| browser_request(lead_path(lead), "PATCH", lead: { email: "#{email}@example.test" }) }
    visit lead_path(lead)
    token = find("input[type=checkbox][name='message[recipient_confirmation]']", visible: :all).value
    %w[b c].each do |email|
      browser_request(lead_messages_path(lead), "POST", message: {
        to: "#{email}@example.test", body: "Cycle", subject: "Cycle", recipient_confirmation: token
      })
      assert_equal "a@example.test", Message.order(:id).last.to_addrs
    end
    browser_request(lead_path(lead), "PATCH", lead: { email: "" })
    browser_request(lead_path(lead), "PATCH", lead: { email: "a@example.test" })
    count = Message.count
    response = browser_request(lead_messages_path(lead), "POST", message: {
      to: "a@example.test", body: "Stale confirmation", subject: "Stale", recipient_confirmation: token
    })
    assert_includes response["body"], "confirm the current recipients"
    assert_equal count, Message.count
    Client.create!(name: "Conflicting owner", email: "b@example.test")
    template = Template.create!(name: "Conflict check", purpose: "custom", subject: "Update", body: "Update")
    response = browser_request(group_sends_path, "POST", template_id: template.id, recipients: "alternate@example.test\nb@example.test")
    assert_includes response["body"], "matches multiple records"
    assert_equal count, Message.count
    assert_equal 0, GroupSend.count
    record("cycle-and-conflict", { cycle_destinations: "a@example.test", stale_confirmation_rejected: true, conflicting_batch_messages_created: Message.count - count })
  end

  test "conversion into shared PerfectBook client blocks colliding draft until current recipient is selected" do
    client = Client.create!(name: "Existing party", email: "d@example.test", perfectbook_contact_id: 9101)
    person = client.people.create!(name: "Other traveler", email: "b@example.test")
    person.update!(email: "c@example.test")
    lead = Lead.create!(name: "Returning traveler", email: "a@example.test", source: "manual", perfectbook_contact_id: 9101)
    original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Previously queued" })
    original.conversation.create_draft!(owner: lead, to_addrs: lead.email, body: "For returning traveler")
    browser_request(lead_path(lead), "PATCH", lead: { email: "b@example.test" })
    browser_request(convert_lead_path(lead), "POST", expected_client_id: client.id)
    assert_equal client, lead.reload.converted_client
    [ client_path(client), inbox_thread_path(original.conversation) ].each do |path|
      visit path
      envelope
      assert_field "To", with: "b@example.test"
      assert_field "message_body", with: "For returning traveler"
    end
    count = Message.count
    check "I confirm these are the intended current recipients."
    click_button "Send", exact: true
    assert_text "Choose a current recipient"
    assert_equal count, Message.count
    envelope
    capture("shared-client-collision-blocked")
    fill_in "To", with: "d@example.test"
    check "I confirm these are the intended current recipients."
    click_button "Send", exact: true
    assert_text "Sending your reply"
    assert_equal count + 1, Message.count
    outgoing = Message.order(:id).last
    assert_equal "d@example.test", outgoing.to_addrs
    ClientMailer.outbound(outgoing).deliver_now
    assert_equal [ "d@example.test" ], ActionMailer::Base.deliveries.last.to
    assert_equal "a@example.test", original.reload.to_addrs
    assert_equal "queued", original.status
    record("shared-client-collision-delivery", { delivered_to: ActionMailer::Base.deliveries.last.to,
      body: outgoing.text_body, historical_to: original.to_addrs, other_traveler: person.reload.email })
  end

  [ false, true ].each do |subsequent_correction|
    test "retained old person address uses corrected owner for reply and group with later correction #{subsequent_correction}" do
      lead = Lead.create!(name: "Intended Traveler", email: "old@example.test", source: "manual")
      lead.people.create!(name: "Other Traveler", email: lead.email)
      moving = lead.people.create!(name: "Moving Traveler", email: "new@example.test") if subsequent_correction
      original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Original history" })
      original.conversation.create_draft!(owner: lead, to_addrs: lead.email, body: "Saved draft")
      [ [ 8301, "Other Traveler", "old@example.test", "OTHER", 11100 ],
        [ 8302, "Intended Traveler", "new@example.test", "INTENDED", 22200 ] ].each do |id, name, email, invoice, balance|
        PerfectBook::Contact.create!(perfectbook_id: id, name: name, email: email, synced_at: Time.current)
        PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: id,
          trip_name: "#{name} trek", invoice_number: invoice, balance_due_minor: balance, synced_at: Time.current)
      end
      template = Template.create!(name: "Corrected details", purpose: "first_reply",
        subject: "For {{full_name}}", body: "{{full_name}}: {{trip}} {{balance_due}} {{invoice_number}}")
      expected_body = "Intended Traveler: Intended Traveler trek $222.00 INTENDED"
      visit edit_lead_path(lead)
      fill_in "Primary email", with: "new@example.test"
      click_button "Save changes"
      assert_selector "h1", text: lead.name
      if moving
        browser_request(lead_path(lead), "PATCH", lead: { people_attributes: {
          "0" => { id: moving.id, name: moving.name, email: "person-new@example.test" }
        } })
      end
      count = Message.count
      response = browser_request(lead_messages_path(lead), "POST", conversation_id: original.conversation_id,
        message: { to: "old@example.test", body: "Unconfirmed stale form" })
      assert_includes response["body"], "confirm the current recipients"
      assert_equal count, Message.count
      visit lead_path(lead)
      envelope
      assert_field "To", with: "new@example.test"
      fill_in "Message", with: ""
      click_button "Corrected details", match: :first
      assert_field "Message", with: expected_body
      assert_unchecked_field "I confirm these are the intended current recipients."
      confirmation = find("input[name='message[recipient_confirmation]']").value
      capture("retained-reply-confirmation-#{subsequent_correction}")
      check "I confirm these are the intended current recipients."
      click_button "Send", exact: true
      assert_text "Sending your reply"
      reply = Message.order(:id).last
      assert_equal "new@example.test", reply.to_addrs
      assert_includes reply.text_body, expected_body
      assert_not_includes reply.text_body, "OTHER"
      browser_request(lead_messages_path(lead), "POST", conversation_id: original.conversation_id,
        message: { to: "old@example.test", subject: "Confirmed stale form", body: expected_body,
          recipient_confirmation: confirmation })
      stale_reply = Message.order(:id).last
      assert_not_equal reply.id, stale_reply.id
      assert_equal "new@example.test", stale_reply.to_addrs

      visit merge_templates_path(template_id: template.id)
      fill_in "Recipients", with: "old@example.test"
      tolerate_submit_navigation { click_button "Preview merge" }
      tolerate_navigation_assertion { assert_text "1 message ready" }
      within("section[aria-label='Merged messages']") do
        assert_text "<new@example.test>"
        assert_text expected_body
        assert_no_text "OTHER"
      end
      assert_unchecked_field "I confirm the listed recipients for Intended Traveler."
      capture("retained-group-confirmation-#{subsequent_correction}")
      count = Message.count
      tolerate_submit_navigation { click_button "Send 1 personal emails" }
      tolerate_navigation_assertion { assert_text "confirm the current recipients" }
      assert_equal count, Message.count
      assert_equal 0, GroupSend.count
      tolerate_submit_navigation { click_button "Preview merge" }
      check "I confirm the listed recipients for Intended Traveler."
      tolerate_submit_navigation { click_button "Send 1 personal emails" }
      tolerate_navigation_assertion { assert_selector "h1", text: "Send summary" }
      group_message = GroupSend.last.messages.last
      [ reply, stale_reply, group_message ].each_with_index do |message, index|
        OutboundDeliveryJob.perform_now(message.id)
        assert_equal "sent", message.reload.status
        mail = ActionMailer::Base.deliveries.last
        assert_equal [ "new@example.test" ], mail.to
        assert_includes mail.text_part.decoded, expected_body
        assert_not_includes mail.text_part.decoded, "OTHER"
        if ENV["RECIPIENT_EVIDENCE_DIR"]
          File.write(File.join(ENV.fetch("RECIPIENT_EVIDENCE_DIR"), "retained-owner-#{subsequent_correction}-#{index}.eml"), mail.encoded)
        end
      end
      assert_equal "old@example.test", original.reload.to_addrs
      record("retained-owner-delivery-#{subsequent_correction}", {
        reply: reply.slice(:to_addrs, :subject, :text_body, :status),
        stale_reply: stale_reply.slice(:to_addrs, :subject, :text_body, :status),
        group: group_message.slice(:to_addrs, :subject, :text_body, :status), historical_to: original.to_addrs
      })
      if moving
        browser_request(lead_messages_path(lead), "POST", message: { to: moving.reload.email, body: "Deliberate alternate" })
        assert_equal "person-new@example.test", Message.order(:id).last.to_addrs
      end
    end
  end

  private

  def envelope
    details = find("details.reply-details", visible: :all)
    details.find("summary", match: :first).click unless details.matches_css?("[open]")
  end

  # Real HTTP requests from the authenticated browser exercise stale forms and
  # malformed submissions without bypassing controllers or recipient validation.
  def browser_request(path, method, payload = {})
    payload = payload.merge(_method: "patch") if method == "PATCH"
    result = page.driver.browser.execute_async_script(<<~JS, path, method, Rack::Utils.build_nested_query(payload))
      const [path, method, payload, done] = arguments;
      const options = {method: method === "PATCH" ? "POST" : method, headers: {'Accept': 'text/html', 'Content-Type': 'application/x-www-form-urlencoded'}};
      const token = document.querySelector('meta[name="csrf-token"]');
      if (token) options.headers['X-CSRF-Token'] = token.content;
      if (method !== 'GET') options.body = payload;
      fetch(path, options).then(async response => done({status: response.status, body: await response.text()}))
        .catch(error => done({status: 0, body: String(error)}));
    JS
    assert_operator result["status"], :>=, 200, result.inspect
    assert_operator result["status"], :<, 400
    result
  end

  def capture(name)
    return unless ENV["RECIPIENT_EVIDENCE_DIR"]
    if name.include?("confirmation")
      checkbox = find("input[type=checkbox][name*='recipient_confirmation']", visible: :all)
      checkbox.scroll_to(checkbox, align: :center)
    end
    if name == "malformed-draft-editable"
      recipient = find_field("To")
      recipient.scroll_to(recipient, align: :center)
    end
    page.save_screenshot(File.join(ENV.fetch("RECIPIENT_EVIDENCE_DIR"), "#{name}.png"))
  end

  def record(name, value)
    return unless ENV["RECIPIENT_EVIDENCE_DIR"]
    File.write(File.join(ENV.fetch("RECIPIENT_EVIDENCE_DIR"), "#{name}.json"), JSON.pretty_generate(value))
  end
end
