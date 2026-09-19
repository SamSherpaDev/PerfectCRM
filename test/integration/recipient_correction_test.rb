require "test_helper"
require_relative "../support/google_sign_in_test_helper"

# Correcting a lead's wrong address must redirect future sends to the new
# address (envelope and headers), while past messages keep the old address
# and intentionally different recipients stay exactly as addressed.
class RecipientCorrectionTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam Sherpa")
  end

  test "reply defaults and stale submits follow the corrected lead email" do
    lead = Lead.create!(name: "Test Lead", email: "old-wrong@example.test", source: "manual")
    first = Outbound::Composer.call(owner: lead,
      params: { to: "old-wrong@example.test", subject: "Hello", body: "First" })
    conversation = first.conversation

    lead.update!(email: "new-correct@example.test")

    # Empty-To fallback (the reply box default) goes to the correction.
    followup = Outbound::Composer.call(owner: lead.reload, conversation: conversation,
      params: { to: "", subject: "Follow", body: "Second" })
    assert_equal "new-correct@example.test", followup.to_addrs
    assert_equal [ "new-correct@example.test" ], followup.recipients
    assert_equal [ "new-correct@example.test" ], ClientMailer.outbound(followup).to

    # A stale cached form still carrying the old address follows the edit.
    stale = Outbound::Composer.call(owner: lead.reload, conversation: conversation,
      params: { to: "old-wrong@example.test", subject: "Hi", body: "Cached" })
    assert_equal "new-correct@example.test", stale.to_addrs
    assert_equal [ "new-correct@example.test" ], ClientMailer.outbound(stale).to

    # History keeps its attribution; nothing rewrites the first send.
    assert_equal "old-wrong@example.test", first.reload.to_addrs
  end

  test "intentionally different recipients are preserved after a correction" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    client.people.create!(name: "Pemba", email: "pemba@example.com")
    thread = Outbound::Composer.call(owner: client,
      params: { to: "pemba@example.com", subject: "Hi", body: "Hello" }).conversation

    client.update!(email: "maya-new@example.com")

    followup = Outbound::Composer.call(owner: client.reload, conversation: thread,
      params: { to: "", subject: "Hi", body: "Follow" })
    assert_equal "pemba@example.com", followup.to_addrs

    stranger = Outbound::Composer.call(owner: client.reload, conversation: thread,
      params: { to: "stranger@example.com", subject: "Hi", body: "Hello" })
    assert_equal "stranger@example.com", stranger.to_addrs
  end

  test "a corrected contact address follows the same person" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    person = client.people.create!(name: "Pemba", email: "pemba-old@example.com")
    thread = Outbound::Composer.call(owner: client,
      params: { to: "pemba-old@example.com", subject: "Hi", body: "Hello" }).conversation

    person.update!(email: "pemba-new@example.com")

    stale = Outbound::Composer.call(owner: client.reload, conversation: thread,
      params: { to: "pemba-old@example.com", subject: "Hi", body: "Cached" })
    assert_equal "pemba-new@example.com", stale.to_addrs
    assert_equal [ "pemba-new@example.com" ], ClientMailer.outbound(stale).to
  end

  test "composer and saved drafts show the correction, not the old address" do
    lead = Lead.create!(name: "Test Lead", email: "old-wrong@example.test", source: "manual")
    conversation = Outbound::Composer.call(owner: lead,
      params: { to: "old-wrong@example.test", subject: "Hello", body: "First" }).conversation
    conversation.create_draft!(owner: lead, to_addrs: "old-wrong@example.test",
      subject: "Re: Hello", body: "Half written")
    lead.update!(email: "new-correct@example.test")

    sign_in
    get lead_path(lead)
    assert_response :success
    assert_select "input[name='message[to]'][value='new-correct@example.test']"

    patch lead_draft_path(lead), params: {
      conversation_id: conversation.id,
      message: { to: "old-wrong@example.test", subject: "Re: Hello", body: "Half written" }
    }
    assert_equal "new-correct@example.test", conversation.reload.draft.to_addrs
  end

  test "returning to a former address redirects every superseded recipient" do
    lead = Lead.create!(name: "Round trip", email: "first@example.test", source: "manual")
    first = Outbound::Composer.call(owner: lead,
      params: { to: lead.email, subject: "Hello", body: "Original" })
    sign_in
    %w[second third first].each do |address|
      patch lead_path(lead), params: { lead: { email: "#{address}@example.test" } }
      assert_response :redirect
    end

    %w[second third].each do |address|
      get lead_path(lead)
      confirmation = recipient_confirmation_from_form
      assert_difference "Message.count", 1 do
        post lead_messages_path(lead), params: {
          conversation_id: first.conversation_id,
          message: { to: "#{address}@example.test", body: "Follow up", recipient_confirmation: confirmation }
        }
      end
      assert_response :redirect
      assert_equal [ "first@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
    end
    assert_equal "first@example.test", first.reload.to_addrs
    assert_equal "first@example.test", lead.reload.resolve_redirected_email(lead.email)
  end

  test "draft and thread copy recipients follow corrections on display and send" do
    lead = Lead.create!(name: "Copies", email: "wrong@example.test", source: "manual")
    first = Outbound::Composer.call(owner: lead,
      params: { to: "alternate@example.test", cc: lead.email, bcc: lead.email, body: "Original" })
    conversation = first.conversation
    sign_in
    patch lead_path(lead), params: { lead: { email: "right@example.test" } }
    assert_response :redirect

    get lead_path(lead)
    assert_response :success
    assert_select "input[name='message[cc]'][value='right@example.test']"
    assert_select "input[name='message[bcc]']" do |fields|
      assert fields.all? { |field| field["value"].blank? }
    end

    draft = conversation.create_draft!(owner: lead, to_addrs: "alternate@example.test",
      cc_addrs: "wrong@example.test, another@example.test", bcc_addrs: "wrong@example.test", body: "Draft")

    get lead_path(lead)
    assert_response :success
    assert_select "input[name='message[to]'][value='alternate@example.test']"
    assert_select "input[name='message[cc]'][value='right@example.test, another@example.test']"
    assert_select "input[name='message[bcc]'][value='right@example.test']"

    post lead_messages_path(lead), params: {
      conversation_id: conversation.id,
      message: { to: draft.to_addrs, cc: draft.cc_addrs, bcc: draft.bcc_addrs, body: draft.body }
    }
    assert_response :redirect
    mail = ClientMailer.outbound(Message.order(:id).last)
    assert_equal [ "alternate@example.test" ], mail.to
    assert_equal [ "right@example.test", "another@example.test" ], mail.cc
    assert_equal [ "right@example.test" ], mail.bcc
    assert_equal "wrong@example.test", first.reload.cc_addrs
    assert_equal "wrong@example.test", first.bcc_addrs
  end

  test "one edit preserves both owner and nested contact corrections" do
    lead = Lead.create!(name: "Nested", email: "owner-old@example.test", source: "manual")
    person = lead.people.create!(name: "Contact", email: "contact-old@example.test")
    sign_in
    patch lead_path(lead), params: { lead: {
      email: "owner-new@example.test",
      people_attributes: { "0" => { id: person.id, name: person.name, email: "contact-new@example.test" } }
    } }
    assert_response :redirect
    post lead_messages_path(lead), params: { message: {
      to: "owner-old@example.test, contact-old@example.test", body: "Both corrected"
    } }
    assert_response :redirect
    assert_equal [ "owner-new@example.test", "contact-new@example.test" ],
      ClientMailer.outbound(Message.order(:id).last).to
  end

  [ false, true ].each do |returning|
    test "conversion transfers recipient corrections to #{returning ? 'an existing' : 'a new'} client" do
      lead = Lead.create!(name: "Conversion", email: "lead-old@example.test", source: "manual")
      person = lead.people.create!(name: "Contact", email: "person-old@example.test")
      first = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Original" })
      draft = first.conversation.create_draft!(owner: lead, to_addrs: lead.email,
        cc_addrs: person.email, body: "Draft")
      lead.update!(email: "lead-new@example.test")
      person.update!(email: "person-new@example.test")
      if returning
        existing = Client.create!(name: "Existing", email: "client-old@example.test")
        existing.update!(email: lead.email)
      end

      client = lead.reload.convert_to_client!
      assert_equal existing.id, client.id if returning
      assert_equal client, draft.reload.owner
      assert_equal client, first.conversation.reload.linkable
      sign_in
      get client_path(client)
      assert_response :success
      assert_select "input[name='message[to]'][value='lead-new@example.test']"
      assert_select "input[name='message[cc]'][value='person-new@example.test']"
      post client_messages_path(client), params: {
        conversation_id: first.conversation_id,
        message: { to: draft.to_addrs, cc: draft.cc_addrs, body: draft.body }
      }
      assert_response :redirect
      mail = ClientMailer.outbound(Message.order(:id).last)
      assert_equal [ "lead-new@example.test" ], mail.to
      assert_equal [ "person-new@example.test" ], mail.cc
      assert_equal "lead-old@example.test", first.reload.to_addrs
      if returning
        assert_equal "lead-new@example.test", client.reload.resolve_redirected_email("client-old@example.test")
      end
    end
  end

  test "reassigned draft recipients require confirmation and reach the current contact" do
    lead = Lead.create!(name: "Reassignment", email: "owner@example.test", source: "manual")
    person = lead.people.create!(name: "One", email: "reused@example.test")
    queued = Outbound::Composer.call(owner: lead, params: { to: person.email, body: "Already queued" })
    conversation = queued.conversation
    draft = conversation.create_draft!(owner: lead, to_addrs: person.email, body: "Unsent words")
    sign_in
    patch lead_path(lead), params: { lead: { people_attributes: {
      "0" => { id: person.id, name: "One", email: "corrected@example.test" },
      "1" => { name: "Two", email: "reused@example.test" }
    } } }
    assert_response :redirect

    [ nil, "1" ].each do |confirmation|
      assert_no_difference "Message.count" do
        post lead_messages_path(lead), params: { conversation_id: conversation.id,
          message: { to: "reused@example.test", body: draft.body, recipient_confirmation: confirmation } }
      end
      assert_match "confirm the current recipients", flash[:alert]
    end
    assert_equal "reused@example.test", draft.reload.to_addrs
    assert_equal "Unsent words", draft.body

    get inbox_thread_path(conversation)
    assert_response :success
    assert_select "input[name='message[to]'][value='reused@example.test']"
    assert_select "li", text: "Two: reused@example.test"
    confirmation = recipient_confirmation_from_form
    assert_difference "Message.count", 1 do
      post lead_messages_path(lead), params: { conversation_id: conversation.id,
        message: { to: "reused@example.test", body: draft.body, recipient_confirmation: confirmation } }
    end
    assert_equal [ "reused@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
    assert_equal "reused@example.test", queued.reload.to_addrs
    assert_equal "queued", queued.status

    assert_difference "Message.count", 1 do
      post lead_messages_path(lead), params: { message: { to: "alternate@example.test", body: "Deliberate alternate" } }
    end
    assert_equal [ "alternate@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
  end

  [ :owner, :person ].each do |target|
    test "clearing and restoring a #{target} address requires fresh confirmation for copy recipients" do
      lead = Lead.create!(name: "Restoration", email: "owner@example.test", source: "manual")
      contact = target == :owner ? lead : lead.people.create!(name: "Contact", email: "contact@example.test")
      address = contact.email
      contact.update!(email: nil)
      contact.update!(email: address)
      sign_in

      [ :cc, :bcc ].each do |field|
        message_params = { to: "alternate@example.test", field => address, body: "Confirm copies" }
        assert_no_difference "Message.count" do
          post lead_messages_path(lead), params: { message: message_params }
        end
        assert_match "confirm the current recipients", flash[:alert]
        get lead_path(lead, new_thread: 1)
        assert_select "input[name='message[#{field}]'][value='#{address}']"
        stale_confirmation = recipient_confirmation_from_form

        contact.update!(email: nil)
        contact.update!(email: address)
        assert_no_difference "Message.count" do
          post lead_messages_path(lead), params: { message: message_params.merge(recipient_confirmation: stale_confirmation) }
        end
        get lead_path(lead, new_thread: 1)
        confirmation = recipient_confirmation_from_form
        assert_difference "Message.count", 1 do
          post lead_messages_path(lead), params: { message: message_params.merge(recipient_confirmation: confirmation) }
        end
        assert_equal [ address ], ClientMailer.outbound(Message.order(:id).last).public_send(field)
      end
    end
  end

  test "a stale composer owner cannot bypass reassignment confirmation" do
    lead = Lead.create!(name: "Stale owner", email: "owner@example.test", source: "manual")
    person = lead.people.create!(name: "One", email: "reused@example.test")
    stale_owner = Lead.find(lead.id)
    person.update!(email: "corrected@example.test")
    lead.people.create!(name: "Two", email: "reused@example.test")

    assert_no_difference "Message.count" do
      assert_raises ActiveRecord::RecordInvalid do
        Outbound::Composer.call(owner: stale_owner, params: { to: "reused@example.test", body: "Old form" })
      end
    end
  end

  test "correction history survives more than twenty subsequent edits" do
    lead = Lead.create!(name: "Long history", email: "first@example.test", source: "manual")
    original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Original" })
    draft = original.conversation.create_draft!(owner: lead, to_addrs: lead.email, body: "Old draft")
    22.times { |index| lead.update!(email: "correction-#{index}@example.test") }
    person = lead.people.create!(name: "Contact", email: "person-old@example.test")
    person.update!(email: "person-new@example.test")
    sign_in
    get lead_path(lead)
    assert_select "input[name='message[to]'][value='correction-21@example.test']"
    assert_difference "Message.count", 1 do
      post lead_messages_path(lead), params: { conversation_id: original.conversation_id,
        message: { to: draft.to_addrs, body: draft.body } }
    end
    assert_equal [ "correction-21@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
    assert_equal "first@example.test", original.reload.to_addrs
  end

  private

  def recipient_confirmation_from_form
    assert_select "input[type='checkbox'][name='message[recipient_confirmation]']:not([checked])", count: 1
    css_select("input[type='checkbox'][name='message[recipient_confirmation]']").first["value"]
  end
end
