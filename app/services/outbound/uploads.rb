module Outbound
  module Uploads
    REFUSAL = "Sensitive documents live in PerfectBook - attach it there".freeze
    class SensitiveDocument < StandardError
      def initialize
        super(REFUSAL)
      end
    end

    def self.partition(uploads)
      uploads = uploads.values if uploads.is_a?(Hash)
      Array(uploads).compact_blank.partition do |upload|
        if upload.is_a?(ActiveStorage::Blob)
          filename = upload.filename.to_s
          data = upload.download
        elsif upload.is_a?(ActionDispatch::Http::UploadedFile)
          filename = upload.original_filename
          data = upload.read
          upload.rewind
        else
          next false
        end
        !Message.sensitive_attachment?(filename, upload.content_type, data: data)
      end
    end
  end
end
