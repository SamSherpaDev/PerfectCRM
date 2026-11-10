require "test_helper"
require "fugit"
require_relative "../support/graph_fake"

class MailSetAsideRetryJobTest < ActiveSupport::TestCase
  include GraphMessageBuilder

  setup do
    @mailbox = FakeMailbox.new
    Setting.current.update!(ms_graph_refresh_token: "refresh-0", mailbox_watched_since: Time.current.change(usec: 0),
      mailbox_last_error: nil, mailbox_last_error_at: nil, mailbox_last_sync_at: nil)
  end

  def fetcher
    Mail::GraphFetcher.new(transport: @mailbox.transport)
  end

  # Mail live sync gave up on some time ago; `waited` orders the list.
  def set_aside(id, waited:)
    @mailbox.add("inbox", graph_message(id: id, from: "#{id}@example.com", message_id: "<#{id}@test>"))
    MailMessageQuarantine.create!(provider_message_id: id, attempts: MailMessageQuarantine::MAX_ATTEMPTS,
      created_at: waited.ago, updated_at: waited.ago)
  end

  def opened(id)
    @mailbox.requests.count { |request| request.url.include?("/me/messages/#{id}") }
  end

  def waiting
    MailMessageQuarantine.quarantined.order(:updated_at, :id).pluck(:provider_message_id)
  end

  test "set-aside mail that reads is stored like live mail and leaves the list" do
    set_aside("late-one", waited: 3.hours)
    set_aside("late-two", waited: 2.hours)

    assert_difference("Message.count", 2) do
      assert_equal 2, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    end
    stored = Message.find_by!(provider_message_id: "late-one")
    assert_equal "late-one@example.com", stored.from_address
    assert_empty waiting

    # Nothing left to ask Graph for.
    requests = @mailbox.requests.size
    assert_equal 0, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    assert_equal requests, @mailbox.requests.size
  end

  test "a retry that fails keeps the message waiting and carries on to the next one" do
    set_aside("still-refused", waited: 3.hours)
    set_aside("reads-now", waited: 2.hours)
    refused = true
    @mailbox.transport.on_get("/me/messages/still-refused") do |*|
      if refused
        { status: 400, json: { "error" => { "code" => "ErrorInvalidRequest" } } }
      else
        { status: 200, json: @mailbox.find("still-refused") }
      end
    end

    assert_equal 1, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    assert Message.exists?(provider_message_id: "reads-now")
    assert_equal [ "still-refused" ], waiting

    # No give-up limit: it is asked for again every run, for as long as it takes.
    4.times { assert_equal 0, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher) }
    assert_equal 5, opened("still-refused")
    assert_equal [ "still-refused" ], waiting
    assert_equal MailMessageQuarantine::MAX_ATTEMPTS, MailMessageQuarantine.find_by!(provider_message_id: "still-refused").attempts

    refused = false
    assert_equal 1, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    assert Message.exists?(provider_message_id: "still-refused")
    assert_empty waiting
  end

  test "the retry stops at the first outage and starts the next run with the mail that has waited longest since" do
    set_aside("graph-down", waited: 3.hours)
    set_aside("behind-one", waited: 2.hours)
    set_aside("behind-two", waited: 1.hour)
    @mailbox.transport.on_get("/me/messages/graph-down") do |*|
      { status: 503, json: { "error" => { "code" => "ServiceUnavailable" } } }
    end

    assert_no_difference("Message.count") do
      assert_equal 0, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    end
    # One request for the whole run, not one per waiting message.
    assert_equal [ 1, 0, 0 ], [ opened("graph-down"), opened("behind-one"), opened("behind-two") ]
    assert_equal 3, MailMessageQuarantine.quarantined.count

    # A message that keeps answering 5xx is not all of Graph: it went to the
    # back, so it cannot hold up the mail waiting behind it.
    assert_equal %w[behind-one behind-two graph-down], waiting
    assert_equal 2, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    assert Message.exists?(provider_message_id: "behind-one")
    assert Message.exists?(provider_message_id: "behind-two")
    assert_equal [ "graph-down" ], waiting
  end

  test "each run tries at most its cap, longest waiting first" do
    set_aside("third", waited: 1.hour)
    set_aside("first", waited: 3.hours)
    set_aside("second", waited: 2.hours)

    assert_equal 2, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher, limit: 2)
    assert_equal [ "third" ], waiting
    assert_equal 0, opened("third")
  end

  test "set-aside mail that is already stored or gone from the mailbox leaves the list without being stored again" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", graph_message(id: "stored-meanwhile", from: "client@example.com", message_id: "<storedmeanwhile@test>"))
    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
    MailMessageQuarantine.create!(provider_message_id: "stored-meanwhile", attempts: MailMessageQuarantine::MAX_ATTEMPTS)
    MailMessageQuarantine.create!(provider_message_id: "deleted-in-outlook", attempts: MailMessageQuarantine::MAX_ATTEMPTS)
    already_opened = opened("stored-meanwhile")

    assert_no_difference("Message.count") do
      assert_equal 0, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    end
    assert_equal already_opened, opened("stored-meanwhile")
    assert_equal 1, opened("deleted-in-outlook")
    assert_equal 0, MailMessageQuarantine.count
  end

  test "mail still short of the cap is live sync's to read again, not the retry's" do
    @mailbox.add("inbox", graph_message(id: "second-try", from: "client@example.com", message_id: "<secondtry@test>"))
    MailMessageQuarantine.create!(provider_message_id: "second-try", attempts: MailMessageQuarantine::MAX_ATTEMPTS - 1)

    assert_equal 0, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    assert_equal 0, opened("second-try")
    assert_equal 1, MailMessageQuarantine.count
  end

  test "an unconfigured mailbox no-ops" do
    Setting.current.update!(ms_graph_refresh_token: nil)
    MailMessageQuarantine.create!(provider_message_id: "waiting", attempts: MailMessageQuarantine::MAX_ATTEMPTS)

    assert_equal false, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    assert_empty @mailbox.requests
  end

  test "the retry and live sync share one concurrency guard, so they never read the mailbox side by side" do
    assert_equal 1, Mail::SetAsideRetryJob.concurrency_limit
    assert_equal Mail::SyncJob.new.concurrency_key, Mail::SetAsideRetryJob.new.concurrency_key
    assert_equal Mail::SyncJob.concurrency_duration, Mail::SetAsideRetryJob.concurrency_duration
  end

  test "the production schedule runs the retry every hour, in a form Solid Queue accepts" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").fetch("mail_set_aside_retry")
    assert_equal Mail::SetAsideRetryJob, entry.fetch("class").constantize

    # Solid Queue parses a recurring schedule with Fugit and refuses, at
    # boot, anything that is not a single cron.
    cron = Fugit.parse(entry.fetch("schedule"), multi: :fail)
    assert_instance_of Fugit::Cron, cron
    first = cron.next_time(Time.utc(2026, 11, 10, 12, 1))
    assert_equal 1.hour, cron.next_time(first).to_i - first.to_i
  end
end
