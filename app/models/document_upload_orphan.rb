class DocumentUploadOrphan < ApplicationRecord
  def claim!
    count = self.class.where(id: id).update_all(updated_at: Time.current)
    raise ActiveRecord::RecordNotFound unless count == 1
  end

  def self.purge!
    find_each do |orphan|
      transaction do
        orphan.claim!
        attached = ActiveStorage::Attachment.joins(:blob)
          .where(record_type: "DocumentHolding", name: "file", active_storage_blobs: { key: orphan.key })
          .where(record_id: DocumentHolding.select(:id)).exists?
        ActiveStorage::Blob.services.fetch(orphan.service_name).delete(orphan.key) unless attached
        orphan.destroy!
      end
    rescue ActiveRecord::RecordNotFound
      next
    end
  end
end
