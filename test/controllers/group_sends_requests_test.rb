require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class GroupSendsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include ActiveJob::TestHelper

  setup do
    @template = Template.create!(name: "Departure news", purpose: "custom",
      subject: "Hi {{first_name}}", body: "{{full_name}}, see you on {{trip}}!")
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
  end

  test "shared addresses retain each recipient's personalization in preview and send" do
    sign_in
    recipients = "Maya <family@example.com>\nPemba <family@example.com>"
    post merge_templates_path, params: { template_id: @template.id, recipients: recipients }
    assert_response :success
    assert_select "section[aria-label='Merged messages'] li", count: 2 do |rows|
      assert_match(/Hi Maya/, rows[0].text)
      assert_match(/Maya, see you/, rows[0].text)
      assert_match(/Hi Pemba/, rows[1].text)
      assert_match(/Pemba, see you/, rows[1].text)
    end
    assert_enqueued_jobs 2, only: OutboundDeliveryJob do
      post group_sends_path, params: { template_id: @template.id, recipients: recipients }
    end
    messages = GroupSend.last.messages.order(:id).to_a
    assert_equal [ "Hi Maya", "Hi Pemba" ], messages.map(&:subject)
    assert_equal [ "family@example.com", "family@example.com" ], messages.map(&:to_addrs)
    assert_includes messages[0].text_body, "Maya, see you"
    assert_includes messages[1].text_body, "Pemba, see you"
  end

  test "malformed lines refuse the batch and name their lines" do
    sign_in
    post group_sends_path, params: {
      template_id: @template.id, recipients: "Maya Gurung <maya@example.com>\nnot-an-email\n"
    }
    assert_redirected_to %r{/templates/merge}
    follow_redirect!
    assert_select ".flash-alert", text: /Fix 1 line/
    assert_equal 0, GroupSend.count
    assert_equal 0, Message.count
  end

  test "review ask warns about an empty Google link without blocking sends" do
    Setting.current.update!(google_review_url: "")
    @template.update!(purpose: :review_ask, subject: "How was your trip?",
      body: "Please review us.\n\n{{google_review_link}}\n\nThank you")
    sign_in
    params = { template_id: @template.id, recipients: "Maya <maya@example.com>" }

    post merge_templates_path, params: params
    assert_response :success
    assert_select ".badge-warning", text: "Missing: google review link", count: 1
    assert_select "input[type=submit][value='Send 1 personal emails']:not([disabled])", count: 1
    assert_select "section[aria-label='Merged messages'] li", text: /google review link/, count: 0

    assert_enqueued_jobs 1, only: OutboundDeliveryJob do
      post group_sends_path, params: params
    end
    assert_redirected_to group_send_path(GroupSend.last)
    assert_includes GroupSend.last.messages.first.text_body, "Please review us.\n\nThank you"
    assert_not_includes GroupSend.last.messages.first.text_body, "google_review_link"

    Setting.current.update!(google_review_url: "https://g.page/r/example/review")
    post merge_templates_path, params: params
    assert_response :success
    assert_select ".badge-warning", text: "Missing: google review link", count: 0
    assert_select "section[aria-label='Merged messages'] li", text: %r{https://g.page/r/example/review}
  end

  test "other templates do not warn about an empty Google review link" do
    Setting.current.update!(google_review_url: "")
    sign_in
    post merge_templates_path, params: { template_id: @template.id, recipients: "Maya <maya@example.com>" }
    assert_response :success
    assert_select ".badge-warning", text: "Missing: google review link", count: 0
  end

  test "a clean batch sends one personal email each and opens the summary" do
    sign_in
    assert_difference("GroupSend.count", 1) do
      assert_difference("Message.count", 2) do
        assert_enqueued_jobs 2, only: OutboundDeliveryJob do
          post group_sends_path, params: {
            template_id: @template.id,
            recipients: "Maya Gurung <maya@example.com>\nstranger@example.com\n"
          }
        end
      end
    end
    group = GroupSend.last
    assert_redirected_to group_send_path(group)
    follow_redirect!
    assert_select "h1", "Send summary"
    mine = group.messages.find { |message| message.to_list.include?("maya@example.com") }
    assert_equal "Hi Maya", mine.subject
    assert_includes mine.text_body, "Maya Gurung"
    assert_equal @client, mine.owner
    other = group.messages.find { |message| message.to_list.include?("stranger@example.com") }
    assert_nil other.owner
  end

  test "merge preview fills live data and lists broken lines" do
    @client.update!(perfectbook_contact_id: 4242)
    PerfectBook::Booking.create!(perfectbook_id: 9001, perfectbook_contact_id: 4242,
      trip_name: "Everest Base Camp trek", status: "deposit_received",
      balance_due_minor: 185_000, currency: "USD", synced_at: Time.current)
    sign_in
    post merge_templates_path, params: {
      template_id: @template.id,
      recipients: "Maya Gurung <maya@example.com>\nnot-an-email\n"
    }
    assert_response :success
    assert_match(/Everest Base Camp trek/, response.body)
    assert_match(/Line 2/, response.body)
    assert_match(/Not complete/, response.body)
  end

  test "merge takes recipients from a departure's mirrored bookings" do
    departure = PerfectBook::Departure.create!(perfectbook_id: 7001,
      trip_name: "Everest Base Camp trek", label: "May 2027", synced_at: Time.current)
    PerfectBook::Contact.create!(perfectbook_id: 4242, name: "Maya Gurung",
      email: "maya@example.com", synced_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 9002, perfectbook_contact_id: 4242,
      departure_id: 7001, trip_name: "Everest Base Camp trek",
      status: "deposit_received", synced_at: Time.current)
    sign_in
    get merge_templates_path, params: { template_id: @template.id, departure_id: 7001 }
    assert_response :success
    assert_match(/Maya Gurung &lt;maya@example.com&gt;/, response.body)
  end

  test "ambiguous batches confirm current contacts and queue nothing until every recipient validates" do
    @client.update!(email: nil)
    @client.update!(email: "maya@example.com")
    sign_in
    recipients = "stranger@example.test\nMaya <maya@example.com>\nMaya again <maya@example.com>"
    assert_no_difference [ "Message.count", "GroupSend.count", "Conversation.count", "@template.reload.usage_count" ] do
      assert_no_enqueued_jobs only: OutboundDeliveryJob do
        post group_sends_path, params: { template_id: @template.id, recipients: recipients }
      end
    end
    assert_match "confirm the current recipients", flash[:alert]
    post merge_templates_path, params: { template_id: @template.id, recipients: recipients }
    assert_response :success
    assert_select "input[type='checkbox'][name^='recipient_confirmations']:not([checked])", count: 1
    input = css_select("input[type='checkbox'][name^='recipient_confirmations']").first
    confirmations = { @client.to_gid_param => input["value"] }

    @client.update!(email: nil)
    @client.update!(email: "maya@example.com")
    assert_no_difference [ "Message.count", "GroupSend.count" ] do
      assert_no_enqueued_jobs only: OutboundDeliveryJob do
        post group_sends_path, params: { template_id: @template.id, recipients: recipients, recipient_confirmations: confirmations }
      end
    end
    post merge_templates_path, params: { template_id: @template.id, recipients: recipients }
    confirmations[@client.to_gid_param] = css_select("input[type='checkbox'][name^='recipient_confirmations']").first["value"]
    assert_difference "Message.count", 3 do
      assert_difference "GroupSend.count", 1 do
        assert_enqueued_jobs 3, only: OutboundDeliveryJob do
          post group_sends_path, params: { template_id: @template.id, recipients: recipients, recipient_confirmations: confirmations }
        end
      end
    end
    assert_equal [ "stranger@example.test", "maya@example.com", "maya@example.com" ], GroupSend.last.messages.order(:id).map(&:to_addrs)
  end

  test "a later invalid rendered message rolls back the entire group before queuing" do
    @template.update!(subject: "{{first_name}}", body: "{{full_name}}")
    sign_in
    @template.stub(:rendered, ->(context) { { subject: "Hi", body: context["full_name"] == "Invalid" ? "" : "Valid" } }) do
      Template.stub(:find_by, @template) do
        assert_no_difference [ "Message.count", "GroupSend.count", "Conversation.count", "@template.reload.usage_count" ] do
          assert_no_enqueued_jobs only: OutboundDeliveryJob do
            post group_sends_path, params: { template_id: @template.id, recipients: "Valid <valid@example.test>\nInvalid <invalid@example.test>" }
          end
        end
      end
    end
    assert_match "Could not send", flash[:alert]
  end

  test "group recipients with inactive ambiguous history must choose a current address" do
    person = @client.people.create!(name: "One", email: "reused@example.test")
    person.update!(email: "one@example.test")
    second = @client.people.create!(name: "Two", email: "reused@example.test")
    second.update!(email: "two@example.test")
    sign_in
    assert_no_difference [ "Message.count", "GroupSend.count" ] do
      assert_no_enqueued_jobs only: OutboundDeliveryJob do
        post group_sends_path, params: { template_id: @template.id, recipients: "first@example.test\nreused@example.test" }
      end
    end
    assert_match "Choose a current recipient", flash[:alert]
  end

  test "a stale group preview follows ordinary lead correction history" do
    lead = Lead.create!(name: "Traveler", email: "previous@example.test", source: "manual")
    original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Original" })
    recipients = "Traveler <previous@example.test>\nstranger@example.test"
    sign_in
    post merge_templates_path, params: { template_id: @template.id, recipients: recipients }
    assert_response :success
    patch lead_path(lead), params: { lead: { email: "corrected@example.test" } }
    assert_response :redirect

    assert_difference "Message.count", 2 do
      assert_enqueued_jobs 2, only: OutboundDeliveryJob do
        post group_sends_path, params: { template_id: @template.id, recipients: recipients }
      end
    end
    messages = GroupSend.last.messages.order(:id).to_a
    assert_equal [ "corrected@example.test" ], ClientMailer.outbound(messages.first).to
    assert_equal lead, messages.first.owner
    assert_equal [ "stranger@example.test" ], ClientMailer.outbound(messages.last).to
    assert_equal "previous@example.test", original.reload.to_addrs
  end

  [ :history, :current, :person ].each do |conflict|
    test "group resolution rejects correction history conflicting with another #{conflict}" do
      lead = Lead.create!(name: "Original", email: "shared@example.test", source: "manual")
      lead.update!(email: "lead-current@example.test")
      case conflict
      when :history
        @client.update!(email: "shared@example.test")
        @client.update!(email: "client-current@example.test")
      when :current
        @client.update!(email: "shared@example.test")
      when :person
        @client.people.create!(name: "Other", email: "shared@example.test")
      end
      recipients = "stranger@example.test\nshared@example.test"
      sign_in
      post merge_templates_path, params: { template_id: @template.id, recipients: recipients }
      assert_response :unprocessable_entity
      assert_select ".flash-alert", text: /matches multiple records/
      assert_select "form[action=?]", group_sends_path, count: 0
      assert_no_difference [ "Message.count", "GroupSend.count", "Conversation.count" ] do
        assert_no_enqueued_jobs only: OutboundDeliveryJob do
          post group_sends_path, params: { template_id: @template.id, recipients: recipients }
        end
      end
      assert_match "matches multiple records", flash[:alert]

      Draft.create!(owner: lead, to_addrs: "shared@example.test", body: "For original traveler")
      get lead_path(lead, new_thread: 1)
      assert_response :success
      assert_difference "Message.count", 1 do
        post lead_messages_path(lead), params: { message: { to: "shared@example.test", body: "For original traveler" } }
      end
      assert_equal [ "lead-current@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
    end
  end

  test "a historical group recipient exposes confirmation for its restored destination" do
    lead = Lead.create!(name: "Restored", email: "restored@example.test", source: "manual")
    lead.update!(email: "intermediate@example.test")
    lead.update!(email: "restored@example.test")
    sign_in
    post merge_templates_path, params: { template_id: @template.id, recipients: "intermediate@example.test" }
    assert_response :success
    assert_select "input[type='checkbox'][name^='recipient_confirmations']:not([checked])", count: 1
    token = css_select("input[type='checkbox'][name^='recipient_confirmations']").first["value"]
    assert_no_difference "Message.count" do
      post group_sends_path, params: { template_id: @template.id, recipients: "intermediate@example.test" }
    end
    assert_difference "Message.count", 1 do
      post group_sends_path, params: { template_id: @template.id, recipients: "intermediate@example.test",
        recipient_confirmations: { lead.to_gid_param => token } }
    end
    assert_equal [ "restored@example.test" ], ClientMailer.outbound(Message.order(:id).last).to
  end

  [ false, true ].each do |retained|
    test "corrected group delivery uses the corrected mirrored identity when old address retained is #{retained}" do
      @template.update!(subject: "Trip for {{full_name}}", body: "{{full_name}}: {{trip}} {{balance_due}} {{invoice_number}}")
      lead = Lead.create!(name: "Intended Traveler", email: "wrong@example.test", source: "manual", perfectbook_contact_id: 8202)
      PerfectBook::Contact.create!(perfectbook_id: 8201, name: "Other Traveler", email: "wrong@example.test", synced_at: Time.current)
      PerfectBook::Contact.create!(perfectbook_id: 8202, name: "Intended Traveler", email: "correct@example.test", synced_at: Time.current)
      PerfectBook::Contact.create!(perfectbook_id: 8203, name: "Alternate Traveler", email: "alternate@example.test", synced_at: Time.current)
      [ [ 8201, "Other secret trip", 11100, "OTHER-INVOICE" ],
        [ 8202, "Intended trek", 22200, "INTENDED-INVOICE" ],
        [ 8203, "Alternate trek", 33300, "ALTERNATE-INVOICE" ] ].each do |id, trip, balance, invoice|
        PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: id,
          trip_name: trip, balance_due_minor: balance, invoice_number: invoice, synced_at: Time.current)
      end
      lead.people.create!(name: "Other Traveler", email: lead.email) if retained
      original = Outbound::Composer.call(owner: lead, params: { to: lead.email, body: "Previously queued" })
      recipients = "wrong@example.test\nalternate@example.test"
      sign_in
      post merge_templates_path, params: { template_id: @template.id, recipients: recipients }
      assert_response :success
      patch lead_path(lead), params: { lead: { email: "correct@example.test" } }
      assert_response :redirect

      post merge_templates_path, params: { template_id: @template.id, recipients: recipients }
      assert_response :success
      assert_select "section[aria-label='Merged messages'] li" do |rows|
        assert_includes rows.first.text, "correct@example.test"
        assert_not_includes rows.first.text, "wrong@example.test"
        assert_includes rows.first.text, "Intended Traveler: Intended trek $222.00 INTENDED-INVOICE"
        assert_not_includes rows.first.text, "OTHER-INVOICE"
      end
      confirmations = {}
      if retained
        token = css_select("input[type='checkbox'][name^='recipient_confirmations']").first["value"]
        confirmations[lead.to_gid_param] = token
        assert_no_difference "Message.count" do
          post group_sends_path, params: { template_id: @template.id, recipients: recipients }
        end
        assert_match "confirm the current recipients", flash[:alert]
      end

      assert_difference "Message.count", 2 do
        assert_enqueued_jobs 2, only: OutboundDeliveryJob do
          post group_sends_path, params: { template_id: @template.id, recipients: recipients, recipient_confirmations: confirmations }
        end
      end
      messages = GroupSend.last.messages.order(:id).to_a
      assert_equal [ "correct@example.test" ], ClientMailer.outbound(messages.first).to
      assert_equal "Trip for Intended Traveler", messages.first.subject
      assert_includes messages.first.text_body, "Intended Traveler: Intended trek $222.00 INTENDED-INVOICE"
      assert_not_includes messages.first.text_body, "Other"
      assert_not_includes messages.first.text_body, "OTHER-INVOICE"
      assert_equal [ "alternate@example.test" ], ClientMailer.outbound(messages.last).to
      assert_includes messages.last.text_body, "Alternate Traveler: Alternate trek $333.00 ALTERNATE-INVOICE"
      assert_equal "wrong@example.test", original.reload.to_addrs
      assert_includes original.text_body, "Previously queued"

      post merge_templates_path, params: { template_id: @template.id, recipients: recipients }
      assert_response :success
      assert_select "section[aria-label='Merged messages']", text: /Intended Traveler: Intended trek/
      assert_select "section[aria-label='Merged messages']", text: /OTHER-INVOICE/, count: 0
    end
  end
end
