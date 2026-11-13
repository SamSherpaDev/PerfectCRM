require "test_helper"
require "rake"

# The allowlist behind the hourly Drive attachment mirror: only ordinary
# message files qualify, and held documents never do in any state.
class AttachmentBackupTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Backup Client", email: "backup@example.com")
    @conversation = Conversation.create!(subject: "Trip", linkable: @client, last_message_at: Time.current)
    @message = @conversation.messages.create!(direction: "in", from_address: @client.email,
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Trip", sent_at: Time.current, text_body: "attached")
  end

  def blob(filename, content_type = "application/pdf", data: "bytes of #{filename}")
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: filename, content_type: content_type)
  end

  def message_file(filename, content_type = "application/pdf", **options)
    blob(filename, content_type, **options).tap { |file| @message.files.attach(file) }
  end

  def holding_file(filename, expires_at:)
    holding = DocumentHolding.create!(message: @message, filename: filename, content_type: "application/pdf",
      byte_size: 10, expires_at: expires_at)
    blob(filename).tap { |file| holding.file.attach(file) }
  end

  def manifest_keys
    lines = AttachmentBackup.manifest.lines(chomp: true)
    assert_equal AttachmentBackup::MANIFEST_HEADER, lines.first
    assert_equal "end #{lines.size - 2}", lines.last
    lines[1..-2]
  end

  test "ordinary message files qualify and every held or flagged state is excluded" do
    ordinary = message_file("itinerary.pdf", data: "itinerary bytes")
    photo = message_file("summit.jpg", "image/jpeg", data: "jpeg bytes")
    draft = Draft.create!(owner: @client, conversation: @conversation)
    shared = blob("packing-list.pdf", data: "shared bytes")
    draft.files.attach(shared)
    @message.files.attach(shared)

    # A held blob is never a message file today; attaching it to one as well
    # proves the holding attachment alone keeps it out.
    live = holding_file("visa-form.pdf", expires_at: 1.hour.from_now)
    @message.files.attach(live)
    expired = holding_file("ticket.pdf", expires_at: 1.hour.ago)
    @message.files.attach(expired)
    orphan = message_file("upload-in-flight.pdf")
    DocumentUploadOrphan.create!(key: orphan.key, service_name: orphan.service_name)
    marked = message_file("receipt.pdf")
    marked.update!(metadata: marked.metadata.merge("sensitive" => true))
    renamed = message_file("passport.pdf")
    unexpected = message_file("odd-key.pdf")
    unexpected.update_columns(key: "../#{unexpected.key}")
    draft_only = blob("unsent.pdf")
    draft.files.attach(draft_only)
    Setting.current.signature_logo.attach(io: StringIO.new("logo bytes"), filename: "logo.png", content_type: "image/png")

    assert_equal [ ordinary, photo, shared ].map(&:key).sort, manifest_keys
    excluded = [ live, expired, orphan, marked, renamed, unexpected, draft_only, Setting.current.signature_logo.blob ]
    assert_empty manifest_keys & excluded.map(&:key)
  end

  test "manifest holds only the header, sorted keys, and the count trailer" do
    files = 3.times.map { |index| message_file("day-#{index}.pdf") }
    output = AttachmentBackup.manifest
    assert_equal [ AttachmentBackup::MANIFEST_HEADER, *files.map(&:key).sort, "end 3" ].join("\n") + "\n", output
    files.each { |file| assert_match AttachmentBackup::KEY_FORMAT, file.key }
    assert_not_includes output, "day-"
  end

  test "an empty allowlist still prints the header and a zero trailer" do
    assert_equal "#{AttachmentBackup::MANIFEST_HEADER}\nend 0\n", AttachmentBackup.manifest
  end

  test "a widened name rule drops stored matches on the next manifest" do
    stored = message_file("route-notes.pdf")
    assert_equal [ stored.key ], manifest_keys
    Message.stub(:sensitive_attachment?, ->(filename, *, **) { filename.include?("route") }) do
      assert_empty manifest_keys
    end
  end

  test "summary carries counts and bytes only" do
    message_file("itinerary.pdf", data: "12345")
    message_file("map.png", "image/png", data: "1234567")
    message_file("passport.pdf")
    holding_file("visa.pdf", expires_at: 1.hour.from_now)
    DocumentUploadOrphan.create!(key: ActiveStorage::Blob.generate_unique_secure_token, service_name: "test")

    summary = AttachmentBackup.summary
    assert_equal({ "eligible_files" => 2, "eligible_bytes" => 12, "held_files" => 2,
      "flagged_files" => 1, "unexpected_key_files" => 0 }, summary)
    assert_no_match(/itinerary|map|passport|visa/, summary.to_json)
  end

  # deploy/restore-drill.sh checks the Drive mirror with its own SQL against
  # the restored database; it must keep agreeing with the allowlist here.
  def drill_sql(name)
    script = Rails.root.join("deploy/restore-drill.sh").read
    script[/^#{name}="(.*?)"$/m, 1].gsub("\\$", "$")
  end

  test "the restore drill's never-copy and probe queries agree with the allowlist" do
    ordinary = message_file("itinerary.pdf")
    renamed = message_file("passport.pdf")
    live = holding_file("visa-form.pdf", expires_at: 1.hour.from_now)
    expired = holding_file("ticket.pdf", expires_at: 1.hour.ago)
    orphan = message_file("upload-in-flight.pdf")
    DocumentUploadOrphan.create!(key: orphan.key, service_name: orphan.service_name)
    marked = message_file("receipt.pdf")
    marked.update!(metadata: marked.metadata.merge("sensitive" => true))
    cleared = message_file("cleared.pdf")
    cleared.update!(metadata: cleared.metadata.merge("sensitive" => false))

    never_copy = ActiveRecord::Base.connection.select_values(drill_sql("NEVER_COPY_SQL"))
    assert_equal [ live, expired, orphan, marked ].map(&:key).sort, never_copy.sort
    assert_empty never_copy & manifest_keys

    probes = ActiveRecord::Base.connection.select_rows(drill_sql("PROBE_SQL"))
    assert_equal [ ordinary, renamed, cleared ].map(&:key).sort, probes.map(&:first).sort
    assert_equal ordinary.checksum, probes.to_h.fetch(ordinary.key)
    assert_equal [ ordinary, cleared ].map(&:key).sort, manifest_keys
  end

  test "rake tasks print the manifest and summary without filenames" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("backup:attachment_manifest")
    file = message_file("itinerary.pdf")

    output, error = capture_io { Rake::Task["backup:attachment_manifest"].execute }
    assert_empty error
    assert_equal "#{AttachmentBackup::MANIFEST_HEADER}\n#{file.key}\nend 1\n", output

    output, error = capture_io { Rake::Task["backup:attachment_summary"].execute }
    assert_empty error
    assert_equal 1, JSON.parse(output)["eligible_files"]
    assert_not_includes output, "itinerary"
  end
end
