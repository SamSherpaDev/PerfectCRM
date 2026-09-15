module PerfectBook
  class DocumentUploader
    def self.upload(attachment:, booking_id: nil, contact_id: nil)
      new.upload(attachment: attachment, booking_id: booking_id, contact_id: contact_id)
    end

    def upload(attachment:, booking_id: nil, contact_id: nil)
      raise NotImplementedError,
        "PerfectBook has no document upload endpoint yet (needs pb-document-intake: POST /api/v1/contacts/:id/documents)."
    end
  end
end
