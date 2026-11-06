require "test_helper"
require_relative "../support/request_logs_test_helper"

# Oracle: approved November 5 guide-only contract and Marketmate D0 package.
# Exercise the actual API, durable outbox, sender claim, rendered mail and reply ingestion.
class ApiV1GuideRequestsTest < ActionDispatch::IntegrationTest
  include RequestLogsTestHelper
  ROUTE = "/api/v1/guide_requests".freeze
  PDF = "https://cdn.shopify.com/s/files/1/0000/files/private-nepal-journey-guide.pdf".freeze

  setup do
    Setting.current.update!(site_key: "synthetic-public-guide-key", sender_name: "Different ordinary sender",
      email_signature: "Ordinary signature must not enter D0")
    @config = { enabled: true, pdf_url: PDF }
    @payload = { schema: "sherpa.guide-request.v1", email: "guide@example.com", source: "trip_quiz_result" }
    ActionMailer::Base.deliveries.clear
    assert_equal :test, ActionMailer::Base.delivery_method
  end

  def post_guide(payload = @payload, headers: {})
    post ROUTE, params: payload.is_a?(String) ? payload : JSON.generate(payload), headers: {
      "CONTENT_TYPE" => "application/json", "Origin" => "https://www.sherpaholidays.com",
      "X-Sherpa-Site-Key" => "synthetic-public-guide-key"
    }.merge(headers)
  end

  def enabled(&block)
    PrivateNepalGuide.stub(:configuration, @config, &block)
  end

  test "source configuration is inactive with no receipt or send" do
    assert_not PrivateNepalGuide.available?
    assert_no_difference [ "GuideRequest.count", "Message.count", "Lead.count" ] do
      post_guide
    end
    assert_response :service_unavailable
    assert_equal({ "error" => "unavailable" }, response.parsed_body)
    assert_empty ActionMailer::Base.deliveries
  end

  test "disabled switch, invalid final PDF and wrong sender identity fail closed" do
    [ false, nil, "true" ].each do |value|
      PrivateNepalGuide.stub(:configuration, @config.merge(enabled: value)) do
        post_guide
        assert_response :service_unavailable
      end
    end
    [ nil, "[final link]", "https://attacker.example/guide.pdf", "http://www.sherpaholidays.com/guide.pdf",
      "https://www.sherpaholidays.com/guide.pdf?tracking=1" ].each do |url|
      PrivateNepalGuide.stub(:configuration, @config.merge(pdf_url: url)) do
        post_guide
        assert_response :service_unavailable
      end
    end
    enabled do
      Outbound::Composer.stub(:from_address, "other@example.com") do
        post_guide
        assert_response :service_unavailable
      end
    end
    assert_equal 0, GuideRequest.count
  end

  test "guide only succeeds without marketing or call permission and creates no inquiry" do
    enabled do
      assert_no_difference [ "Lead.count", "Person.count", "Client.count", "LeadNotification.count",
        "AutomaticFirstReply.count", "TripQuizEmail.count", "ItineraryEmail.count", "ActivityEvent.count" ] do
        assert_difference [ "GuideRequest.count", "Message.count", "Conversation.count" ], 1 do
          assert_enqueued_jobs 1, only: OutboundDeliveryJob do
            post_guide
          end
        end
      end
      assert_response :accepted
      assert_equal({ "schema" => "sherpa.guide-receipt.v1", "status" => "accepted" }, response.parsed_body)
      assert_equal "no-store", response.headers["Cache-Control"]
      receipt = GuideRequest.last
      assert_equal "queued", receipt.message.status
      assert_nil receipt.message.owner
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test "existing subscribed and unsubscribed synthetic contact records remain byte-for-byte unchanged" do
    # CRM has no Shopify subscription model. These are synthetic source metadata,
    # not proof of provider consent. No provider API is invoked by this path.
    %w[subscribed unsubscribed].each do |state|
      email = "#{state}@example.com"
      lead = Lead.create!(name: "Synthetic Existing #{state}", email: email,
        metadata: { "external_marketing_state" => state })
      client = Client.create!(name: "Synthetic Past #{state}", email: email)
      before = [ lead.attributes, client.attributes ]
      enabled do
        assert_no_difference [ "Lead.count", "Client.count", "Person.count", "LeadNotification.count" ] do
          post_guide(@payload.merge(email: email))
          assert_response :accepted
          OutboundDeliveryJob.perform_now(GuideRequest.find_by!(email: email).message_id)
        end
      end
      assert_equal before, [ lead.reload.attributes, client.reload.attributes ]
    end
    assert_equal 2, ActionMailer::Base.deliveries.size
  end

  test "approved D0 renders exact body and identity without ordinary signature or invented provider URL" do
    enabled do
      post_guide
      receipt = GuideRequest.last
      mail = ClientMailer.outbound(receipt.message).message
      # Independent literal oracle transcribed from immutable approved emails/D0.txt, minus operator-only lines.
      expected = <<~TEXT
        Hello,

        Here is the guide you asked for:
        #{PDF}

        The walking-day questions on page 2 are a useful place to start. The worksheet on page 8 brings your dates, pace and comfort preferences together.

        This email delivers your requested guide. Requesting it does not sign you up for planning notes or a call. If you also chose the five notes, confirm that choice in the separate subscription email.

        Sam and Gyalgin Sherpa
        SherpaHolidays
        775 N 14th Street, San Jose, CA 95112

        Requested SherpaHolidays guide; includes information about our travel services.
        To stop marketing, reply 'unsubscribe'.
      TEXT
      assert_equal "Your private Nepal journey guide", mail.subject
      assert_equal expected, mail.text_part.decoded
      assert_equal [ "info@sherpaholidays.com" ], mail.from
      assert_equal "SherpaHolidays", mail[:from].display_names.first
      assert_equal [ "info@sherpaholidays.com" ], mail.reply_to
      assert_equal [ "guide@example.com" ], mail.to
      assert_equal "auto-generated", mail["Auto-Submitted"].value
      assert_includes mail.html_part.decoded, PDF
      assert_includes mail.html_part.decoded, "reply &#39;unsubscribe&#39;"
      assert_not_includes mail.html_part.decoded, "Ordinary signature"
      [ mail.text_part.decoded, mail.html_part.decoded ].each do |part|
        [ "REVIEW DRAFT", "NOT FOR SENDING", "Timing:", "marketing send tool", "unsubscribe link" ].each do |note|
          assert_not_includes part, note
        end
      end
      assert_empty mail.attachments
      OutboundDeliveryJob.perform_now(receipt.message_id)
      assert_equal "sent", receipt.reload.message.status
      assert_not_nil receipt.delivery_attempted_at
      assert_equal 1, ActionMailer::Base.deliveries.size
    end
  end

  test "repeat requests including case and whitespace reserve one D0 and duplicate jobs do not resend" do
    enabled do
      post_guide
      assert_response :accepted
      receipt = GuideRequest.last
      first_response = response.parsed_body
      post_guide(@payload.merge(email: " GUIDE@example.com "))
      assert_response :accepted
      assert_equal first_response, response.parsed_body
      OutboundDeliveryJob.perform_now(receipt.message_id)
      OutboundDeliveryJob.perform_now(receipt.message_id)
      travel 2.days do
        post_guide
        assert_response :accepted
        GuideRequest.enqueue_pending
      end
      assert_equal 1, GuideRequest.count
      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal 0, LeadNotification.count
    end
  end

  test "overlapping sends share the durable one-attempt claim even when failed mail is manually requeued" do
    enabled do
      post_guide
      receipt = GuideRequest.last
      attempts = 0
      sender = Object.new
      sender.define_singleton_method(:deliver_now) do
        attempts += 1
        OutboundDeliveryJob.perform_now(receipt.message_id)
        raise Net::SMTPServerBusy, "synthetic uncertain acknowledgement"
      end
      ClientMailer.stub(:outbound, sender) do
        assert_no_enqueued_jobs only: OutboundDeliveryJob do
          OutboundDeliveryJob.perform_now(receipt.message_id)
        end
        assert_equal "failed", receipt.reload.message.status
        receipt.message.update!(status: "queued")
        OutboundDeliveryJob.perform_now(receipt.message_id)
      end
      assert_equal 1, attempts
      assert_equal "failed", receipt.reload.message.status
      post_guide
      assert_response :accepted
      assert_equal 1, GuideRequest.count
    end
  end

  test "switching off before delivery prevents sender and does not later replay failed mail" do
    enabled { post_guide }
    receipt = GuideRequest.last
    ClientMailer.stub(:outbound, ->(*) { flunk "inactive guide must not reach sender" }) do
      OutboundDeliveryJob.perform_now(receipt.message_id)
    end
    assert_equal "failed", receipt.reload.message.status
    assert_nil receipt.delivery_attempted_at
    enabled { GuideRequest.enqueue_pending }
    assert_empty ActionMailer::Base.deliveries
  end

  test "queue outage reports unavailable while durable receipt is recovered without new fulfillment" do
    enabled do
      OutboundDeliveryJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError, "synthetic outage" }) do
        post_guide
        assert_response :service_unavailable
      end
      assert_equal 1, GuideRequest.count
      assert_equal "queued", GuideRequest.last.message.status
      assert_enqueued_jobs 1, only: OutboundDeliveryJob do
        GuideRequest.enqueue_pending
      end
      post_guide
      assert_response :accepted
      assert_equal 1, GuideRequest.count
    end
  end

  test "persistence failure returns unavailable without acceptance" do
    enabled do
      GuideRequest.stub(:accept!, ->(**) { raise ActiveRecord::StatementInvalid, "synthetic outage" }) do
        post_guide
      end
      assert_response :service_unavailable
      assert_equal({ "error" => "unavailable" }, response.parsed_body)
      assert_equal 0, GuideRequest.count
    end
  end

  test "validation rejects malformed inputs and extra marketing or phone fields" do
    enabled do
      [ { email: "not an email" }, { email: "x@example.com\r\nBcc: bad@example.com" }, { email: [ "x@example.com" ] },
        { schema: "sherpa.inquiry.v2" }, { source: "landing" }, { marketing: true }, { phone: "synthetic" },
        { honeypot: "robot" } ].each do |change|
        post_guide(@payload.merge(change))
        assert_response :bad_request
        assert_equal "validation", response.parsed_body["error"]
      end
      [ "{", "[]", " " * 2049 ].each do |raw|
        post_guide(raw)
        assert_response :bad_request
        assert_equal "bad_request", response.parsed_body["error"]
      end
      assert_equal 0, GuideRequest.count
    end
  end

  test "only the two storefront origins and existing public site key are accepted" do
    enabled do
      [ { "Origin" => "https://attacker.example" }, { "Origin" => "" }, { "X-Sherpa-Site-Key" => "wrong" },
        { "X-Sherpa-Signature" => "not-a-relay-interface" } ].each do |headers|
        post_guide(headers: headers)
        assert_response :forbidden
      end
      post_guide(headers: { "Origin" => "https://sherpaholidays.com" })
      assert_response :accepted
    end
    options ROUTE, headers: { "Origin" => "https://www.sherpaholidays.com" }
    assert_response :no_content
    assert_equal "https://www.sherpaholidays.com", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Access-Control-Allow-Headers"], "X-Sherpa-Site-Key"
    options ROUTE, headers: { "Origin" => "https://attacker.example" }
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "email throttling returns retry-after without another fulfillment" do
    enabled do
      3.times { post_guide }
      post_guide
      assert_response :too_many_requests
      assert_equal "rate_limited", response.parsed_body["error"]
      assert_operator response.headers["Retry-After"].to_i, :>, 0
      assert_equal 1, GuideRequest.count
    end
  end

  test "request logs redact email and unknown free text" do
    enabled do
      logs = capture_request_logs do
        post_guide(@payload.merge(email: "guide-private@example.com", extra: "SyntheticPrivateText"))
      end
      assert_not_includes logs, "guide-private@example.com"
      assert_not_includes logs, "SyntheticPrivateText"
    end
  end

  test "reply unsubscribe remains in the existing info mailbox thread for operator suppression and never enrolls or replies" do
    enabled do
      post_guide
      receipt = GuideRequest.last
      OutboundDeliveryJob.perform_now(receipt.message_id)
      original = receipt.message
      raw = "From: guide@example.com\r\nTo: info@sherpaholidays.com\r\n" \
        "Subject: Re: Your private Nepal journey guide\r\nMessage-ID: <synthetic-stop@example.com>\r\n" \
        "In-Reply-To: <#{original.message_id}>\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nunsubscribe"
      parsed = Mail::Ingester.parse_raw(raw)
      assert_no_difference [ "Lead.count", "Person.count", "LeadNotification.count", "AutomaticFirstReply.count", "GuideRequest.count" ] do
        result = Mail::Ingester.ingest(parsed: parsed, provider: { message_id: "synthetic-guide-stop" })
        assert_equal :stored, result[:status]
        assert_equal original.conversation_id, result[:message].conversation_id
        assert_equal "unsubscribe", result[:message].text_body.strip
        assert result[:message].unread?
      end
      assert_equal 1, ActionMailer::Base.deliveries.size
    end
  end
end
