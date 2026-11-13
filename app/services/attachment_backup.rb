# Decides which stored files the hourly encrypted Drive mirror may hold.
#
# Ordinary attachments and held identity documents share one private bucket
# under random keys, so only the database can tell them apart: the host job
# (deploy/drive-attachments-backup.sh) copies exactly this allowlist and
# deletes every Drive copy whose key has left it. Operations and retention:
# docs/operations.md, "Attachments backup".
module AttachmentBackup
  MANIFEST_HEADER = "perfectcrm-attachment-manifest v1".freeze
  # Active Storage's own key format (Blob::MINIMUM_TOKEN_LENGTH base36
  # characters). Keys become Drive file names, so anything else is refused.
  KEY_FORMAT = /\A[0-9a-z]{28}\z/

  HELD_SQL = <<~SQL.squish.freeze
    EXISTS (SELECT 1 FROM active_storage_attachments held
      WHERE held.blob_id = active_storage_blobs.id AND held.record_type = 'DocumentHolding')
  SQL
  ORPHAN_SQL = <<~SQL.squish.freeze
    EXISTS (SELECT 1 FROM document_upload_orphans
      WHERE document_upload_orphans.key = active_storage_blobs.key)
  SQL

  Entry = Struct.new(:key, :byte_size, :checksum, :created_at, :exclusion, keyword_init: true)

  module_function

  # "perfectcrm-attachment-manifest v1", the sorted eligible keys, then
  # "end <count>". Keys only: never a filename or any other field.
  def manifest
    keys = entries.select { |entry| entry.exclusion.nil? }.map(&:key)
    [ MANIFEST_HEADER, *keys, "end #{keys.size}" ].join("\n") + "\n"
  end

  # Counts and bytes for sizing and post-deploy checks; no key or filename.
  def summary
    rows = entries
    eligible = rows.select { |entry| entry.exclusion.nil? }
    counts = rows.map(&:exclusion).compact.tally
    {
      "eligible_files" => eligible.size,
      "eligible_bytes" => eligible.sum(&:byte_size),
      "held_files" => held_keys.size,
      "flagged_files" => counts.fetch(:flagged, 0),
      "unexpected_key_files" => counts.fetch(:unexpected_key, 0)
    }
  end

  # The Drive restore drill (deploy/restore-drill.sh) runs this offline
  # against a restored database and compares the result with the Drive
  # listing. Keys go only to these two files, never to output. "never-copy"
  # holds every key this rule keeps off Drive: held, in flight, flagged by
  # the marker or by name and type, or malformed. "eligible" holds every
  # allowlisted file as "key|checksum|created-at epoch", newest first.
  def write_drill_sets(directory)
    rows = entries
    never_copy = (rows.select(&:exclusion).map(&:key) + held_keys).uniq.sort
    eligible = rows.select { |entry| entry.exclusion.nil? }.sort_by(&:created_at).reverse
    File.write(File.join(directory, "never-copy"), never_copy.map { |key| "#{key}\n" }.join)
    File.write(File.join(directory, "eligible"),
      eligible.map { |entry| "#{entry.key}|#{entry.checksum}|#{entry.created_at.to_i}\n" }.join)
  end

  # Every file attached to a sent or received message (Message#files), in
  # key order, with the first rule that keeps it off Drive. Drafts, the
  # signature logo and holdings are never message files. One SELECT reads
  # the attachments, holdings and upload orphans as a single consistent
  # snapshot without taking SQLite's write lock.
  def entries
    message_blob_ids = ActiveStorage::Attachment.where(record_type: "Message", name: "files").select(:blob_id)
    ActiveStorage::Blob.where(id: message_blob_ids).order(:key)
      .pluck(:key, :filename, :content_type, :metadata, :byte_size, :checksum, :created_at,
        Arel.sql(HELD_SQL), Arel.sql(ORPHAN_SQL))
      .map do |key, filename, content_type, metadata, byte_size, checksum, created_at, held, orphan|
        Entry.new(key: key, byte_size: byte_size.to_i, checksum: checksum, created_at: created_at,
          exclusion: exclusion(key, filename, content_type, metadata, truthy_sql?(held) || truthy_sql?(orphan)))
      end
  end

  # Held documents never qualify, whatever state their holding is in.
  # Flagged covers the captain's marker and today's name and type rule, so
  # widening Message.sensitive_attachment? drops old matches on the next run.
  def exclusion(key, filename, content_type, metadata, held)
    return :held if held
    return :flagged if flagged_metadata?(metadata)
    return :flagged if ::Message.sensitive_attachment?(filename.to_s, content_type.to_s)
    return :unexpected_key unless key.to_s.match?(KEY_FORMAT)

    nil
  end

  # Same truthiness as the thread's "Potentially sensitive" badge; metadata
  # that cannot be read counts as flagged.
  def flagged_metadata?(metadata)
    metadata = JSON.parse(metadata) if metadata.is_a?(String)
    return false if metadata.nil?
    return true unless metadata.is_a?(Hash)

    metadata["sensitive"] ? true : false
  rescue JSON::ParserError
    true
  end

  # Keys of blobs in the holding area plus uploads still in flight; a held
  # file that is also attached to a message is counted here, not under flagged.
  def held_keys
    held = ActiveStorage::Blob.where(id: ActiveStorage::Attachment.where(record_type: "DocumentHolding").select(:blob_id)).pluck(:key)
    (held + DocumentUploadOrphan.pluck(:key)).uniq
  end

  def truthy_sql?(value)
    value == true || value.to_i == 1
  end
end
