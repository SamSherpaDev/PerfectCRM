require "test_helper"

class AutomaticFirstReplyJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  setup do
    Setting.current.update!(auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago,
      sender_name: "Sam", email_signature: "Sam\nSherpaHolidays")
    @template = Template.create!(name: "First reply", purpose: :first_reply, channel: "email",
      subject: "Your {{trip}}", body: "Hi {{first_name}},\nLet's arrange a call.\n{{signature}}")
    @lead = Lead.create!(name: "Synthetic Traveler", email: "synthetic@gmail.com", capture_channel: "website_form",
      external_ref: "website_form:#{SecureRandom.uuid}", created_at: 3.minutes.ago, trip_title: "Nepal tour")
  end

  test "current approved row renders and delivers once with manual-send timeline state" do
    @template.update!(name: "First reply to a new inquiry", body: "Hi {{first_name}},\nLive wording and a call.\n{{signature}}")
    2.times { AutomaticFirstReplyJob.perform_now(@lead.id) }
    assert_equal 1, AutomaticFirstReply.where(email: @lead.email).count
    message = AutomaticFirstReply.find_by!(email: @lead.email).message
    assert_equal [ @lead.email ], message.to_list
    assert_equal "Your Nepal tour", message.subject
    assert_includes message.text_body, "Live wording and a call"
    assert_equal 1, message.text_body.scan("SherpaHolidays").size
    assert_equal @lead, message.owner
    assert_equal "queued", message.status
    assert_emails 1 do
      2.times { OutboundDeliveryJob.perform_now(message.id) }
    end
    assert message.reload.sent?
    assert_equal "new", @lead.reload.status
    assert_includes @lead.activity_events.where(kind: "automation").pluck(:summary), "Automatic first reply: sent"
  end

  test "direct replay cannot bypass two minute delay" do
    @lead.update_columns(created_at: Time.current)
    assert_no_difference("Message.count") do
      assert_enqueued_with(job: AutomaticFirstReplyJob, args: [ @lead.id ], at: @lead.created_at + 2.minutes) do
        AutomaticFirstReplyJob.perform_now(@lead.id)
      end
    end
  end

  test "different submissions for same address reserve only once forever" do
    AutomaticFirstReplyJob.perform_now(@lead.id)
    original = AutomaticFirstReply.find_by!(email: @lead.email)
    duplicate = Lead.create!(name: "Second Inquiry", email: @lead.email, capture_channel: "website_form",
      external_ref: "website_form:#{SecureRandom.uuid}", created_at: 3.minutes.ago)
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(duplicate.id) }
    assert_includes duplicate.activity_events.last.summary, "already reserved"
    original.message.destroy!
    assert_nil original.reload.message
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(duplicate.id) }
  end

  {
    "setting is off" => ->(lead) { Setting.current.update!(auto_first_reply_enabled: false) },
    "old inquiry" => ->(lead) { lead.update_columns(created_at: 2.hours.ago) },
    "not a website inquiry" => ->(lead) { lead.update!(capture_channel: "email") },
    "invalid email" => ->(lead) { lead.update_columns(email: "bad-address") },
    "our own domain" => ->(lead) { lead.update!(email: "team@sherpaholidays.com") },
    "test address" => ->(lead) { lead.update!(email: "visitor@example.org") },
    "spam or junk" => ->(lead) { lead.update!(spam_score: 10) },
    "inactive inquiry" => ->(lead) { lead.update!(archived_at: Time.current) },
    "existing client" => ->(lead) { Client.create!(name: "Existing", email: lead.email) }
  }.each do |reason, prepare|
    test "skips and logs #{reason}" do
      prepare.call(@lead)
      assert_no_difference([ "Message.count", "AutomaticFirstReply.count" ]) { AutomaticFirstReplyJob.perform_now(@lead.id) }
      assert_includes @lead.activity_events.where(kind: "automation").last.summary, reason
    end
  end

  test "all reserved example and special domains are skipped" do
    %w[example.com example.org example.net sub.example.com local.test localhost].each do |domain|
      @lead.update_columns(email: "visitor@#{domain}")
      assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
      assert_includes @lead.activity_events.where(kind: "automation").last.summary, "test address"
    end
  end

  test "a marked test inquiry is never emailed even at a real domain" do
    @lead.update!(is_test: true)
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
    assert_includes @lead.activity_events.where(kind: "automation").last.summary, "test address"
  end

  test "Panda spam verdict and suspected-spam tag both block sending" do
    @lead.update!(fit_reason: "Junk inquiry")
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
    @lead.update!(fit_reason: nil, tag_list: Lead::SUSPECTED_SPAM_TAG)
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
  end

  test "imported outbound cc contact blocks greeting" do
    conversation = @lead.conversations.create!(subject: "Prior mail")
    conversation.messages.create!(direction: "out", status: "received", from_address: Mail.mailbox_address,
      to_addresses: [ "another@gmail.com" ], cc_addresses: [ @lead.email ], text_body: "Earlier", sent_at: 1.day.ago)
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
    assert_includes @lead.activity_events.where(kind: "automation").last.summary, "already contacted"
  end

  test "manual queued To and Bcc messages prevent automatic contact" do
    message = Outbound::Composer.call(owner: @lead, params: { to: @lead.email, subject: "Manual", body: "Already writing" })
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
    assert_includes @lead.activity_events.where(kind: "automation").last.summary, "already contacted"
    message.update!(to_addrs: "another@gmail.com", bcc_addrs: @lead.email)
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
    assert_includes @lead.activity_events.where(kind: "automation").last.summary, "already contacted"
  end

  test "a client person address also blocks the first reply" do
    client = Client.create!(name: "Client", email: "other@gmail.com")
    client.people.create!(name: "Same Traveler", email: @lead.email)
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
    assert_includes @lead.activity_events.where(kind: "automation").last.summary, "existing client"
  end

  test "recipient confirmation gates are never bypassed" do
    Lead.stub(:find, @lead) do
      @lead.stub(:ambiguous_recipient_emails, [ @lead.email ]) do
        @lead.stub(:current_recipient_emails, [ @lead.email ]) do
          assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
        end
      end
    end
    assert_includes @lead.activity_events.where(kind: "automation").last.summary, "sending gate"
  end

  test "missing marker and unavailable template are logged" do
    @template.update!(body: "Hi {{first_name}} {{unknown_value}}")
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
    assert_includes @lead.activity_events.where(kind: "automation").last.summary, "missing placeholder"
    @template.archive!
    assert_no_difference("Message.count") { AutomaticFirstReplyJob.perform_now(@lead.id) }
    assert_includes @lead.activity_events.where(kind: "automation").last.summary, "unavailable"
  end

  test "late kill switch and spam verdict stop queued delivery" do
    AutomaticFirstReplyJob.perform_now(@lead.id)
    message = AutomaticFirstReply.find_by!(lead: @lead).message
    Setting.current.update!(auto_first_reply_enabled: false)
    assert_emails(0) { OutboundDeliveryJob.perform_now(message.id) }
    assert message.reload.failed?
    assert_includes message.send_error, "setting is off"
    Setting.current.update!(auto_first_reply_enabled: true)
    message.update!(status: "queued")
    @lead.update!(fit_reason: "Spam")
    assert_emails(0) { OutboundDeliveryJob.perform_now(message.id) }
    assert_includes message.reload.send_error, "spam or junk"
  end

  test "address corrections after queueing do not silently change the automatic recipient" do
    AutomaticFirstReplyJob.perform_now(@lead.id)
    message = AutomaticFirstReply.find_by!(lead: @lead).message
    @lead.update!(email: "corrected@gmail.com")
    assert_emails(0) { OutboundDeliveryJob.perform_now(message.id) }
    assert_includes message.reload.send_error, "address changed"
    assert_equal [ "synthetic@gmail.com" ], message.to_list
  end

  test "automatic reply never consumes an owner draft or its files" do
    draft = Draft.for_owner(@lead, conversation: nil)
    draft.update!(subject: "Private draft", body: "Do not send this")
    draft.files.attach(io: StringIO.new("private"), filename: "private.txt", content_type: "text/plain")
    AutomaticFirstReplyJob.perform_now(@lead.id)
    message = AutomaticFirstReply.find_by!(lead: @lead).message
    assert_not message.files.attached?
    assert_nil message.submitted_draft_id
    assert_emails(1) { OutboundDeliveryJob.perform_now(message.id) }
    assert_equal "Do not send this", draft.reload.body
  end

  test "SMTP uncertainty never retries an automatic first reply" do
    AutomaticFirstReplyJob.perform_now(@lead.id)
    message = AutomaticFirstReply.find_by!(lead: @lead).message
    delivery = Object.new
    def delivery.deliver_now
      raise IOError, "Acknowledgement lost"
    end
    ClientMailer.stub(:outbound, delivery) { OutboundDeliveryJob.perform_now(message.id) }
    assert message.reload.failed?
    # Even a timeline Retry cannot repeat an uncertain automatic send.
    message.update!(status: "queued")
    assert_emails(0) do
      AutomaticFirstReplyJob.perform_now(@lead.id)
      OutboundDeliveryJob.perform_now(message.id)
    end
  end

  test "creating manual lead and other templates does not send automatically" do
    assert_no_enqueued_jobs do
      Lead.create!(name: "Manual", email: "manual@gmail.com")
      Template.create!(name: "Follow up", purpose: :itinerary_follow_up, body: "Manual only", channel: "email")
      @lead.update!(status: "chatting")
    end
    assert_equal 0, Message.outbound.count
  end
end
