require "test_helper"
require "minitest/mock"

class DocumentUploadOrphanTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @message_id = "orphan-#{SecureRandom.uuid}"
    @keys = []
  end

  teardown do
    message = Message.find_by(gm_message_id: @message_id)
    DocumentHolding.where(message: message).find_each(&:purge!) if message
    message&.conversation&.destroy!
    @import&.destroy!
    @keys.each { |key| ActiveStorage::Blob.service.delete(key) }
    DocumentUploadOrphan.where(key: @keys).delete_all
  end

  test "outer rollback retains prepared cleanup keys until the sweep succeeds" do
    raw = "From: orphan@example.com\r\nTo: info@sherpaholidays.com\r\nMessage-ID: <#{@message_id}@test>\r\nSubject: Documents\r\n\r\nAttached"
    parsed = Mail::Ingester.parse_raw(raw)
    parsed.attachments = [
      { filename: "passport.pdf", content_type: "application/pdf", data: "passport bytes" },
      { filename: "visa.png", content_type: "image/png", data: "visa bytes" }
    ]
    prepared = Mail::Ingester.prepare(parsed: parsed)
    service = ActiveStorage::Blob.service
    upload = service.method(:upload)
    failing_upload = lambda do |key, io, **options|
      @keys << key
      assert DocumentUploadOrphan.exists?(key: key)
      raise IOError, "upload unavailable" if @keys.size == 2

      upload.call(key, io, **options)
    end

    assert_no_difference([ "Message.count", "Conversation.count", "DocumentHolding.count",
      "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ]) do
      service.stub(:upload, failing_upload) do
        service.stub(:delete, ->(*) { raise IOError, "deletion unavailable" }) do
          assert_raises(IOError) do
            Message.transaction do
              Mail::Ingester.ingest(parsed: parsed, gmail: { gm_msgid: @message_id }, prepared: prepared)
            end
          end
        end
      end
    end
    assert_equal 2, @keys.size
    assert_equal @keys.sort, DocumentUploadOrphan.where(key: @keys).pluck(:key).sort
    assert service.exist?(@keys.first)
    service.stub(:delete, ->(*) { raise IOError, "still unavailable" }) do
      assert_raises(IOError) { DocumentHoldingsPurgeJob.perform_now }
    end
    assert_equal 2, DocumentUploadOrphan.where(key: @keys).count

    DocumentHoldingsPurgeJob.perform_now
    @keys.each { |key| assert_not service.exist?(key) }
    assert_empty DocumentUploadOrphan.where(key: @keys)

    result = Mail::Ingester.ingest(parsed: parsed, gmail: { gm_msgid: @message_id })
    assert_equal :stored, result[:status]
    holdings = DocumentHolding.where(message: result[:message]).order(:id).to_a
    assert_equal [ "passport bytes", "visa bytes" ], holdings.map { |holding| holding.file.download }
    committed_keys = holdings.map { |holding| holding.file.blob.key }
    @keys.concat(committed_keys)
    assert_empty DocumentUploadOrphan.where(key: committed_keys)

    blob = holdings.first.file.blob
    DocumentUploadOrphan.create!(key: blob.key, service_name: blob.service_name)
    DocumentHoldingsPurgeJob.perform_now
    assert_equal "passport bytes", holdings.first.reload.file.download
    assert_empty DocumentUploadOrphan.where(key: committed_keys)
  end

  test "history import retains cleanup reservations when upload and rollback deletion fail" do
    mail = ::Mail.new do
      from "orphan@example.com"
      to "info@sherpaholidays.com"
      subject "Documents"
      body "Attached"
    end
    mail.message_id = "#{@message_id}@test"
    mail.attachments["passport.pdf"] = { mime_type: "application/pdf", content: "passport bytes" }
    mail.attachments["visa.png"] = { mime_type: "image/png", content: "visa bytes" }
    item = Struct.new(:raw, :gmail, :uid, :uid_validity).new(
      mail.to_s, { gm_msgid: @message_id }, 1, 123)
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_all) do |**options, &block|
      options[:on_mailbox].call(123)
      block.call(item)
    end
    @import = MailImport.create!(scope: "all", status: "draft")
    service = ActiveStorage::Blob.service
    upload = service.method(:upload)
    failing_upload = lambda do |key, io, **options|
      @keys << key
      assert Message.connection.transaction_open?
      raise IOError, "upload unavailable" if @keys.size == 2

      upload.call(key, io, **options)
    end
    assert_no_difference([ "Message.count", "Conversation.count", "DocumentHolding.count",
      "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ]) do
      service.stub(:upload, failing_upload) do
        service.stub(:delete, ->(*) { raise IOError, "deletion unavailable" }) do
          assert_raises(IOError) { Mail::ImportJob.perform_now(@import.id, fetcher: fetcher) }
        end
      end
    end
    assert_equal "failed", @import.reload.status
    assert_equal 0, @import.processed_messages
    assert_equal 0, @import.preview_json["import_uid"]
    assert_equal 2, @keys.size
    assert_equal @keys.sort, DocumentUploadOrphan.where(key: @keys).pluck(:key).sort
    assert service.exist?(@keys.first)

    DocumentHoldingsPurgeJob.perform_now
    @keys.each { |key| assert_not service.exist?(key) }
    assert_empty DocumentUploadOrphan.where(key: @keys)

    Mail::ImportJob.perform_now(@import.id, fetcher: fetcher)
    assert_equal "done", @import.reload.status
    assert_equal 1, @import.processed_messages
    assert_equal 1, @import.preview_json["import_uid"]
    message = Message.find_by!(gm_message_id: @message_id)
    holdings = DocumentHolding.where(message: message).order(:id).to_a
    assert_equal [ "passport bytes", "visa bytes" ], holdings.map { |holding| holding.file.download }
    assert_empty DocumentUploadOrphan.where(key: holdings.map { |holding| holding.file.blob.key })
  end

  test "unprepared ingestion inside an outer transaction fails before uploading" do
    parsed = Mail::Ingester.parse_raw("From: orphan@example.com\r\nTo: info@sherpaholidays.com\r\n\r\nAttached")
    parsed.attachments = [ { filename: "passport.pdf", content_type: "application/pdf", data: "passport bytes" } ]
    uploads = []
    ActiveStorage::Blob.service.stub(:upload, ->(*) { uploads << true }) do
      assert_raises(ActiveRecord::ActiveRecordError) do
        Message.transaction do
          Mail::Ingester.ingest(parsed: parsed, gmail: { gm_msgid: @message_id })
        end
      end
    end
    assert_empty uploads
    assert_not Message.exists?(gm_message_id: @message_id)
  end

  test "a swept reservation cannot subsequently upload bytes" do
    orphan = DocumentUploadOrphan.create!(key: SecureRandom.base58(28), service_name: ActiveStorage::Blob.service.name)
    @keys << orphan.key
    DocumentHoldingsPurgeJob.perform_now
    assert_raises(ActiveRecord::RecordNotFound) do
      DocumentUploadOrphan.transaction { orphan.claim! }
    end
  end
end
