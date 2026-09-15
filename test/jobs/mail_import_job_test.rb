require "test_helper"

class FakeImportImap
  Fetched = Struct.new(:uid, :uid_validity, :raw, :gmail, keyword_init: true)

  def initialize(raws)
    @raws = raws.each_with_index.to_h { |raw, index| [ index + 1, raw ] }
  end

  def fetch_all(since: nil, limit: nil, after_uid: 0, uid_validity: nil, on_mailbox: nil)
    return enum_for(:fetch_all, since: since, limit: limit) unless block_given?

    on_mailbox&.call(123)
    after_uid = 0 unless uid_validity == 123
    @raws.each do |uid, raw|
      next if uid <= after_uid.to_i

      yield Fetched.new(uid: uid, uid_validity: 123, raw: raw, gmail: { gm_thrid: nil, gm_msgid: nil, labels: [] })
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
    assert_equal 0, import.linked_messages
    assert_equal 3, import.skipped_messages
    assert_equal 3, import.processed_messages
  end
  test "choices link already ingested outbound conversations" do
    raw = "From: info@sherpaholidays.com\r\nTo: outbound@example.com\r\nMessage-ID: <outbound-import@test>\r\n\r\nHi"
    result = Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw), gmail: {})
    import = MailImport.create!(scope: "all", status: "preview", preview_json: { "choices" => { "outbound@example.com" => "client" } })
    assert_difference("Client.count", 1) do
      assert_no_difference("Message.count") { Mail::ImportJob.new.perform(import.id, fetcher: FakeImportImap.new([ raw ])) }
    end
    assert result[:conversation].reload.linked?
    assert_equal 1, import.reload.linked_messages
    assert_equal 1, import.created_clients
  end

  test "resume uses stable UIDs when earlier mail disappears" do
    raws = (1..3).map { |n| "From: sender#{n}@example.com\r\nTo: info@sherpaholidays.com\r\nMessage-ID: <resume#{n}@test>\r\n\r\nHello" }
    import = MailImport.create!(scope: "all", status: "preview", preview_json: {})
    fetcher = FakeImportImap.new(raws)
    original = Mail::Ingester.method(:ingest)
    Mail::Ingester.stub(:ingest, ->(**args) { args[:parsed].message_id == "resume2@test" ? raise("interrupted") : original.call(**args) }) do
      assert_raises(RuntimeError) { Mail::ImportJob.new.perform(import.id, fetcher: fetcher) }
    end
    assert_equal 1, import.reload.preview_json["import_uid"]
    fetcher.instance_variable_get(:@raws).delete(1)
    assert_difference("Message.count", 2) { Mail::ImportJob.new.perform(import.id, fetcher: fetcher) }
    assert_equal 3, import.reload.processed_messages
  end

end
