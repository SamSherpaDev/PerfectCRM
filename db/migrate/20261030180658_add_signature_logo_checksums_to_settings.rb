class AddSignatureLogoChecksumsToSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :settings, :signature_logo_checksums, :text, default: "[]", null: false

    checksums = select_values(<<~SQL.squish)
      SELECT active_storage_blobs.checksum
      FROM active_storage_attachments
      INNER JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id
      WHERE active_storage_attachments.record_type = 'Setting'
        AND active_storage_attachments.name = 'signature_logo'
        AND active_storage_blobs.checksum IS NOT NULL
    SQL
    return if checksums.empty?

    execute "UPDATE settings SET signature_logo_checksums = #{connection.quote(checksums.uniq.to_json)}"
  end

  def down
    remove_column :settings, :signature_logo_checksums
  end
end
