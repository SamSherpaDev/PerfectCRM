# Handoff for sensitive attachments the captain wants out of the CRM.
# PerfectBook stays the system of record for passports, visas, insurance,
# and every traveler document, so the CRM never keeps those files: the
# captain picks the traveler/booking and the file is handed to PerfectBook.
#
# TODO (PerfectBook task pb-document-intake): PerfectBook exposes no upload
# endpoint yet. When it ships `POST /api/v1/contacts/:id/documents`
# (token-authed, idempotent), implement #upload there and keep this
# interface unchanged. Until then every call raises NotImplemented with a
# clear message instead of silently keeping the file.
module PerfectBook
  class DocumentUploader
    def self.upload(attachment:, booking_id: nil, contact_id: nil)
      new.upload(attachment: attachment, booking_id: booking_id, contact_id: contact_id)
    end

    def upload(attachment:, booking_id: nil, contact_id: nil)
      filename = attachment.try(:filename).to_s.presence || "attachment"
      raise NotImplementedError,
        "PerfectBook has no document upload endpoint yet (needs pb-document-intake: POST /api/v1/contacts/:id/documents). " \
        "Kept #{filename} in the CRM instead of moving it."
    end
  end
end
