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

  test "reassignment ambiguity survives later edits and conversion without guessing" do
    lead = Lead.create!(name: "History", email: "owner@example.test", source: "manual")
    first_person = lead.people.create!(name: "One", email: "reused@example.test")
    queued = Outbound::Composer.call(owner: lead, params: { to: first_person.email, body: "Original" })
    draft = queued.conversation.create_draft!(owner: lead, to_addrs: first_person.email, body: "For One")
    first_person.update!(email: "one@example.test")
    second_person = lead.reload.people.create!(name: "Two", email: "reused@example.test")
    sign_in
    get lead_path(lead)
    stale_confirmation = recipient_confirmation_from_form
    second_person.update!(email: "two@example.test")

    [ nil, stale_confirmation ].each do |confirmation|
      assert_no_difference "Message.count" do
        post lead_messages_path(lead), params: { conversation_id: queued.conversation_id,
          message: { to: draft.to_addrs, body: draft.body, recipient_confirmation: confirmation } }
      end
      assert_match "Choose a current recipient", flash[:alert]
    end
    get lead_path(lead)
    assert_select "input[name='message[to]'][value='reused@example.test']"
    confirmation = recipient_confirmation_from_form
    assert_no_difference "Message.count" do
      post lead_messages_path(lead), params: { conversation_id: queued.conversation_id,
        message: { to: draft.to_addrs, body: draft.body, recipient_confirmation: confirmation } }
    end
    assert_equal "reused@example.test", draft.reload.to_addrs
    assert_equal "For One", draft.body

    client = lead.reload.convert_to_client!
    assert_no_difference "Message.count" do
      post client_messages_path(client), params: { conversation_id: queued.conversation_id,
        message: { to: draft.to_addrs, body: draft.body } }
    end
    assert_match "Choose a current recipient", flash[:alert]
    get client_path(client)
    confirmation = recipient_confirmation_from_form
    assert_difference "Message.count", 1 do
      post client_messages_path(client), params: { conversation_id: queued.conversation_id,
        message: { to: "one@example.test", body: draft.body, recipient_confirmation: confirmation } }
    end
    assert_equal [ "one@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
    assert_equal "reused@example.test", queued.reload.to_addrs
    assert_equal "queued", queued.status
  end

  test "formatted To Cc and Bcc mailboxes follow corrections and preserve alternates" do
    lead = Lead.create!(name: "Alice", email: "old@example.test", source: "manual")
    original = Outbound::Composer.call(owner: lead,
      params: { to: '"Alice, Traveler" <old@example.test>', body: "Original" })
    original.conversation.create_draft!(owner: lead, to_addrs: '"Alice, Traveler" <old@example.test>', body: "Draft")
    lead.update!(email: "corrected@example.test")
    sign_in
    get lead_path(lead)
    assert_select "input[name='message[to]'][value='corrected@example.test']"
    post lead_messages_path(lead), params: { conversation_id: original.conversation_id, message: {
      to: '"Alice, Traveler" <OLD@example.test>, Friend <alternate@example.test>',
      cc: "Alice <old@example.test>", bcc: "Alice <old@example.test>", body: "Corrected"
    } }
    assert_response :redirect
    mail = ClientMailer.outbound(Message.order(:id).last)
    assert_equal [ "corrected@example.test", "alternate@example.test" ], mail.to
    assert_equal [ "corrected@example.test" ], mail.cc
    assert_equal [ "corrected@example.test" ], mail.bcc
    assert_equal "old@example.test", original.reload.to_addrs
  end

  test "formatted recipients cannot bypass ambiguity confirmation in any envelope field" do
    lead = Lead.create!(name: "Alice", email: "alice@example.test", source: "manual")
    lead.update!(email: nil)
    lead.update!(email: "alice@example.test")
    sign_in
    %i[to cc bcc].each do |field|
      message = { to: "alternate@example.test", field => '"Alice, Traveler" <ALICE@example.test>', body: "Check recipient" }
      assert_no_difference "Message.count" do
        post lead_messages_path(lead), params: { message: message }
      end
      assert_match "confirm the current recipients", flash[:alert]
      get lead_path(lead, new_thread: 1)
      confirmation = recipient_confirmation_from_form
      assert_difference "Message.count", 1 do
        post lead_messages_path(lead), params: { message: message.merge(recipient_confirmation: confirmation) }
      end
      assert_equal [ "alice@example.test" ], ClientMailer.outbound(Message.order(:id).last).public_send(field)
    end
  end

  [ :person, :owner ].each do |new_contact|
    test "adding a #{new_contact} address cannot inherit another person's cleared address" do
      lead = Lead.create!(name: "Cleared address", source: "manual")
      person = lead.people.create!(name: "One", email: "cleared@example.test")
      original = Outbound::Composer.call(owner: lead, params: { to: person.email, body: "Already queued" })
      draft = original.conversation.create_draft!(owner: lead, to_addrs: person.email, body: "Unsent for One")
      sign_in
      patch lead_path(lead), params: { lead: { people_attributes: {
        "0" => { id: person.id, name: "One", email: "" }
      } } }
      assert_response :redirect
      attributes = if new_contact == :person
        { people_attributes: { "0" => { name: "Two", email: "unrelated@example.test" } } }
      else
        { email: "unrelated@example.test" }
      end
      patch lead_path(lead), params: { lead: attributes }
      assert_response :redirect
      assert_no_difference "Message.count" do
        post lead_messages_path(lead), params: { conversation_id: original.conversation_id,
          message: { to: "cleared@example.test", body: draft.body } }
      end
      assert_match "Could not send", flash[:alert]
      assert_equal "Unsent for One", draft.reload.body
      assert_equal "cleared@example.test", original.reload.to_addrs
      assert_equal "queued", original.status

      patch lead_path(lead), params: { lead: { people_attributes: {
        "0" => { id: person.id, name: "One", email: "cleared@example.test" }
      } } }
      assert_response :redirect
      assert_no_difference "Message.count" do
        post lead_messages_path(lead), params: { conversation_id: original.conversation_id,
          message: { to: "cleared@example.test", body: draft.body } }
      end
      assert_match "confirm the current recipients", flash[:alert]
      get lead_path(lead)
      confirmation = recipient_confirmation_from_form
      assert_difference "Message.count", 1 do
        post lead_messages_path(lead), params: { conversation_id: original.conversation_id,
          message: { to: "cleared@example.test", body: draft.body, recipient_confirmation: confirmation } }
      end
      assert_equal [ "cleared@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
    end
  end

  [ false, true ].each do |reverse_order|
    [ false, true ].each do |swap|
      test "simultaneous #{swap ? 'swaps' : 'reassignments'} preserve chains with reverse order #{reverse_order}" do
        lead = Lead.create!(name: "Nested reassignment", email: "owner@example.test", source: "manual")
        addresses = { "One" => "a@example.test", "Two" => "b@example.test" }
        names = reverse_order ? %w[Two One] : %w[One Two]
        people = names.to_h { |name| [ name, lead.people.create!(name: name, email: addresses[name]) ] }
        unrelated = lead.people.create!(name: "Unrelated", email: "unrelated-old@example.test")
        unrelated.update!(email: "unrelated-current@example.test")
        original = Outbound::Composer.call(owner: lead, params: { to: "a@example.test", body: "Original for One" })
        draft = original.conversation.create_draft!(owner: lead, to_addrs: "a@example.test", body: "Draft for One")
        sign_in
        patch lead_path(lead), params: { lead: { people_attributes: {
          "0" => { id: people["One"].id, name: "One", email: "b@example.test" },
          "1" => { id: people["Two"].id, name: "Two", email: swap ? "a@example.test" : "c@example.test" }
        } } }
        assert_response :redirect
        assert_equal "b@example.test", people["One"].reload.email
        assert_equal swap ? "a@example.test" : "c@example.test", people["Two"].reload.email
        assert_no_difference "Message.count" do
          post lead_messages_path(lead), params: { conversation_id: original.conversation_id,
            message: { to: "a@example.test", body: draft.body } }
        end
        assert_match "confirm the current recipients", flash[:alert]
        get lead_path(lead)
        confirmation = recipient_confirmation_from_form
        assert_difference "Message.count", 1 do
          post lead_messages_path(lead), params: { conversation_id: original.conversation_id,
            message: { to: "b@example.test", body: draft.body, recipient_confirmation: confirmation } }
        end
        assert_equal [ "b@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
        assert_equal "a@example.test", original.reload.to_addrs
        assert_equal "queued", original.status

        assert_difference "Message.count", 1 do
          post lead_messages_path(lead), params: { message: { to: "unrelated-old@example.test", body: "Unaffected chain" } }
        end
        assert_equal [ "unrelated-current@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
        assert_difference "Message.count", 1 do
          post lead_messages_path(lead), params: { message: { to: "alternate@example.test", body: "Deliberate alternate" } }
        end
        assert_equal [ "alternate@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
      end
    end
  end

  [ false, true ].each do |returning|
    test "conversion into #{returning ? 'existing' : 'new'} client preserves simultaneous reassignment boundaries" do
      lead = Lead.create!(name: "Conversion boundary", email: "owner@example.test", source: "manual")
      one = lead.people.create!(name: "One", email: "a@example.test")
      two = lead.people.create!(name: "Two", email: "b@example.test")
      unrelated = lead.people.create!(name: "Unrelated", email: "unrelated-old@example.test")
      unrelated.update!(email: "unrelated-current@example.test")
      original = Outbound::Composer.call(owner: lead, params: { to: "a@example.test", body: "Queued for One" })
      draft = original.conversation.create_draft!(owner: lead, to_addrs: "a@example.test", body: "Unsent for One")
      if returning
        existing = Client.create!(name: "Existing", email: "existing-old@example.test")
        existing.update!(email: lead.email)
      end
      sign_in
      patch lead_path(lead), params: { lead: { people_attributes: {
        "0" => { id: one.id, name: "One", email: "b@example.test" },
        "1" => { id: two.id, name: "Two", email: "c@example.test" }
      } } }
      assert_response :redirect
      post convert_lead_path(lead), params: { expected_client_id: existing&.id || "new" }
      client = lead.reload.converted_client
      assert_not_nil client
      assert_redirected_to client_path(client)
      assert_equal existing.id, client.id if returning
      assert_equal client, draft.reload.owner
      assert_no_difference "Message.count" do
        post client_messages_path(client), params: { conversation_id: original.conversation_id,
          message: { to: "a@example.test", body: draft.body } }
      end
      assert_match "confirm the current recipients", flash[:alert]
      get client_path(client)
      assert_select "input[name='message[to]'][value='b@example.test']"
      confirmation = recipient_confirmation_from_form
      assert_difference "Message.count", 1 do
        post client_messages_path(client), params: { conversation_id: original.conversation_id,
          message: { to: "b@example.test", body: draft.body, recipient_confirmation: confirmation } }
      end
      assert_equal [ "b@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
      assert_equal "a@example.test", original.reload.to_addrs
      assert_equal "queued", original.status
      assert_difference "Message.count", 1 do
        post client_messages_path(client), params: { message: { to: "unrelated-old@example.test", body: "Unaffected" } }
      end
      assert_equal [ "unrelated-current@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
      if returning
        assert_difference "Message.count", 1 do
          post client_messages_path(client), params: { message: { to: "existing-old@example.test", body: "Existing history" } }
        end
        assert_equal [ "owner@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
      end
    end
  end

  test "malformed saved recipients remain editable on record and thread pages" do
    lead = Lead.create!(name: "Alice", email: "alice@example.test", source: "manual", perfectbook_contact_id: 8501)
    PerfectBook::Booking.create!(perfectbook_id: 8502, perfectbook_contact_id: 8501,
      trip_name: "Private booking", synced_at: Time.current)
    original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Original" })
    conversation = original.conversation
    malformed = "Alice <alice@example.test"
    sign_in
    patch lead_draft_path(lead), params: { conversation_id: conversation.id,
      message: { to: malformed, subject: "Unfinished", body: "Words to keep" } }
    assert_response :redirect
    assert_equal malformed, conversation.reload.draft.to_addrs

    [ lead_path(lead), inbox_thread_path(conversation) ].each do |path|
      get path
      assert_response :success
      assert_select "input[name='message[to]']" do |fields|
        assert_equal malformed, fields.first["value"]
      end
      assert_select "textarea[name='message[body]']", text: "Words to keep"
    end
    get reply_context_templates_path, params: { owner_type: "Lead", owner_id: lead.id, to: malformed }
    assert_response :success
    assert_equal({ "context" => {}, "selected_booking_id" => nil, "bookings" => [], "booking_contexts" => {} }, response.parsed_body)

    assert_no_difference "Message.count" do
      post lead_messages_path(lead), params: { conversation_id: conversation.id,
        message: { to: malformed, subject: "Unfinished", body: "Words to keep" } }
    end
    assert_match "Enter valid recipient email addresses", flash[:alert]
    follow_redirect!
    assert_response :success
    assert_equal malformed, conversation.reload.draft.to_addrs
    assert_equal "Words to keep", conversation.draft.body
    assert_difference "Message.count", 1 do
      post lead_messages_path(lead), params: { conversation_id: conversation.id,
        message: { to: "Alice <alice@example.test>", subject: "Finished", body: "Words to keep" } }
    end
    assert_equal [ "alice@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
    assert_equal "alice@example.test", original.reload.to_addrs
  end

  test "conversion by PerfectBook ID cannot join the lead address to another person's history" do
    client = Client.create!(name: "Existing client", email: "d@example.test", perfectbook_contact_id: 9101)
    person = client.people.create!(name: "Other traveler", email: "b@example.test")
    person.update!(email: "c@example.test")
    lead = Lead.create!(name: "Returning traveler", email: "a@example.test", source: "manual", perfectbook_contact_id: 9101)
    original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Previously queued" })
    draft = original.conversation.create_draft!(owner: lead, to_addrs: lead.email, body: "For returning traveler")
    sign_in
    patch lead_path(lead), params: { lead: { email: "b@example.test" } }
    assert_response :redirect
    post convert_lead_path(lead), params: { expected_client_id: client.id }
    assert_redirected_to client_path(client)
    assert_equal client, lead.reload.converted_client
    assert_equal client, draft.reload.owner

    [ client_path(client), inbox_thread_path(original.conversation) ].each do |path|
      get path
      assert_response :success
      assert_select "input[name='message[to]'][value='b@example.test']"
      assert_select "textarea[name='message[body]']", text: "For returning traveler"
    end
    confirmation = recipient_confirmation_from_form
    [ [ "a@example.test", nil ], [ "b@example.test", confirmation ] ].each do |address, token|
      assert_no_difference [ "Message.count", "ActionMailer::Base.deliveries.size" ] do
        post client_messages_path(client), params: { conversation_id: original.conversation_id,
          message: { to: address, body: draft.body, recipient_confirmation: token } }
      end
      assert_match "Choose a current recipient", flash[:alert]
    end
    assert_equal "For returning traveler", draft.reload.body
    get client_path(client)
    confirmation = recipient_confirmation_from_form
    assert_difference "Message.count", 1 do
      post client_messages_path(client), params: { conversation_id: original.conversation_id,
        message: { to: "d@example.test", body: draft.body, recipient_confirmation: confirmation } }
    end
    outgoing = Message.order(:id).last
    assert_difference "ActionMailer::Base.deliveries.size", 1 do
      ClientMailer.outbound(outgoing).deliver_now
    end
    assert_equal [ "d@example.test" ], ActionMailer::Base.deliveries.last.to
    assert_equal "a@example.test", original.reload.to_addrs
    assert_equal "queued", original.status
    assert_equal "c@example.test", person.reload.email
  end

  test "confirmed stale sends follow the owner correction when a person still holds the old address" do
    # A fresh lead created directly with the new address is the proven
    # working path; it is removed so the corrected lead can take the address.
    fresh = Lead.create!(name: "Fresh", email: "owner-new@example.test", source: "manual")
    fresh_send = Outbound::Composer.call(owner: fresh,
      params: { to: "", subject: "Hello", body: "Fresh words" })
    assert_equal "owner-new@example.test", fresh_send.to_addrs
    assert_equal [ "owner-new@example.test" ], ClientMailer.outbound(fresh_send).to
    fresh.destroy!

    lead = Lead.create!(name: "Correction", email: "owner-old@example.test", source: "manual")
    lead.people.create!(name: "Mate", email: "owner-old@example.test")
    first = Outbound::Composer.call(owner: lead,
      params: { to: "owner-old@example.test", subject: "Hello", body: "First" })
    conversation = first.conversation
    sign_in

    # The captain's edit: record shows the new address afterwards.
    patch lead_path(lead), params: { lead: { email: "owner-new@example.test" } }
    assert_response :redirect
    assert_equal "owner-new@example.test", lead.reload.email
    assert_equal "owner-new@example.test",
      lead.effective_recipient_email("owner-old@example.test")

    # A stale submit carrying the old address cannot slip through unconfirmed.
    assert_no_difference "Message.count" do
      post lead_messages_path(lead), params: { conversation_id: conversation.id,
        message: { to: "owner-old@example.test", subject: "Stale", body: "Cached words" } }
    end
    assert_match "confirm the current recipients", flash[:alert]

    # The reply default on the old thread follows the correction once confirmed.
    get lead_path(lead)
    confirmation = recipient_confirmation_from_form
    assert_difference "Message.count", 1 do
      post lead_messages_path(lead), params: { conversation_id: conversation.id,
        message: { to: "", subject: "Follow", body: "Reply words",
          recipient_confirmation: confirmation } }
    end
    assert_response :redirect
    assert_equal [ "owner-new@example.test" ], ClientMailer.outbound(Message.order(:id).last).to

    # Confirming an explicit stale address follows it to the new envelope.
    get lead_path(lead)
    confirmation = recipient_confirmation_from_form
    assert_difference "Message.count", 1 do
      post lead_messages_path(lead), params: { conversation_id: conversation.id,
        message: { to: "owner-old@example.test", subject: "Stale", body: "Cached words",
          recipient_confirmation: confirmation } }
    end
    assert_response :redirect
    corrected = Message.order(:id).last
    assert_equal "owner-new@example.test", corrected.to_addrs
    assert_equal [ "owner-new@example.test" ], ClientMailer.outbound(corrected).to

    # A deliberate alternate still passes through untouched.
    assert_difference "Message.count", 1 do
      post lead_messages_path(lead), params: { message: { to: "stranger@example.test", body: "Hello" } }
    end
    assert_equal [ "stranger@example.test" ], ClientMailer.outbound(Message.order(:id).last).to

    # History keeps its attribution; nothing rewrites the first send.
    assert_equal "owner-old@example.test", first.reload.to_addrs
  end

  [ false, true ].each do |subsequent_correction|
    test "retained old owner address resolves before rendering with subsequent person correction #{subsequent_correction}" do
      lead = Lead.create!(name: "Intended Traveler", email: "old@example.test", source: "manual")
      lead.people.create!(name: "Other Traveler", email: lead.email)
      person = lead.people.create!(name: "Moving Traveler", email: "new@example.test") if subsequent_correction
      original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Original" })
      [ [ 8301, "Other Traveler", "old@example.test", "OTHER", 11100 ],
        [ 8302, "Intended Traveler", "new@example.test", "INTENDED", 22200 ] ].each do |id, name, email, invoice, balance|
        PerfectBook::Contact.create!(perfectbook_id: id, name: name, email: email, synced_at: Time.current)
        PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: id,
          trip_name: "#{name} trek", invoice_number: invoice, balance_due_minor: balance, synced_at: Time.current)
      end
      template = Template.create!(name: "Personal details", purpose: "custom", subject: "For {{full_name}}",
        body: "{{full_name}}: {{trip}} {{balance_due}} {{invoice_number}}")
      sign_in
      patch lead_path(lead), params: { lead: { email: "new@example.test" } }
      assert_response :redirect
      if subsequent_correction
        patch lead_path(lead), params: { lead: { people_attributes: {
          "0" => { id: person.id, name: person.name, email: "person-new@example.test" }
        } } }
        assert_response :redirect
        assert_equal "new@example.test", lead.reload.email
        assert_equal "person-new@example.test", person.reload.email
      end
      assert_no_difference "Message.count" do
        post lead_messages_path(lead), params: { conversation_id: original.conversation_id,
          message: { to: "old@example.test", body: "Unconfirmed" } }
      end
      assert_match "confirm the current recipients", flash[:alert]
      get lead_path(lead)
      assert_response :success
      assert_select "input[name='message[to]'][value='new@example.test']"
      confirmation = recipient_confirmation_from_form

      get reply_context_templates_path, params: { owner_type: "Lead", owner_id: lead.id, to: "old@example.test" }
      assert_response :success
      post use_template_path(template, format: :json), params: { context: response.parsed_body["context"] }
      assert_response :success
      rendered = response.parsed_body
      assert_equal "For Intended Traveler", rendered["subject"]
      assert_includes rendered["body"], "Intended Traveler: Intended Traveler trek $222.00 INTENDED"
      assert_not_includes rendered["body"], "OTHER"
      assert_difference "Message.count", 1 do
        post lead_messages_path(lead), params: { conversation_id: original.conversation_id, message: {
          to: "old@example.test", subject: rendered["subject"], body: rendered["body"],
          template_id: template.id, recipient_confirmation: confirmation
        } }
      end
      mail = ClientMailer.outbound(Message.order(:id).last)
      assert_equal [ "new@example.test" ], mail.to
      assert_includes mail.text_part.decoded, "Intended Traveler: Intended Traveler trek $222.00 INTENDED"
      assert_not_includes mail.text_part.decoded, "OTHER"
      if subsequent_correction
        assert_difference "Message.count", 1 do
          post lead_messages_path(lead), params: { message: { to: person.email, body: "For the person" } }
        end
        assert_equal [ "person-new@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
      end
      assert_equal "old@example.test", original.reload.to_addrs
    end
  end

  private

  def recipient_confirmation_from_form
    assert_select "input[type='checkbox'][name='message[recipient_confirmation]']:not([checked])", count: 1
    css_select("input[type='checkbox'][name='message[recipient_confirmation]']").first["value"]
  end
end
