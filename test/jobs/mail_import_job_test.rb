require "test_helper"

class FakeImportImap
  Fetched = Struct.new(:raw, :gmail, keyword_init: true)

  def initialize(raws)
    @raws = raws
  end

  def fetch_all(since: nil, limit: nil)
    return enum_for(:fetch_all, since: since, limit: limit) unless block_given?

    @raws.each do |raw|
      yield Fetched.new(raw: raw, gmail: { gm_thrid: nil, gm_msgid: nil, labels: [] })
    end
  end
end

class MailImportJobTest < ActiveSupport::TestCase
  test "import is resumable and respects the info@ rule" do
    import = MailImport.create!(scope: "all", status: "draft", total_messages: 3)
    raws = [
      "From: a@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: x\r\nMessage-ID: <i1@t>\r\n\r\nb",
      "From: friend@gmail.com\r\nTo: captain@gmail.com\r\nSubject: private\r\nMessage-ID: <i2@t>\r\n\r\nb",
      "From: b@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: y\r\nMessage-ID: <i3@t>\r\n\r\nb"
    ]
    Mail::ImportJob.new.perform(import.id, fetcher: FakeImportImap.new(raws))
    import.reload
    assert_equal "done", import.status
    assert_equal 2, import.linked_messages
    assert_equal 1, import.skipped_messages
    assert_equal 3, import.processed_messages
  end
end
