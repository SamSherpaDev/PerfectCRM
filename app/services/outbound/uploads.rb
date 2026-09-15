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
        _ordinary, held = ::Mail::Ingester.partition_attachments(
          [ { filename: filename, content_type: upload.content_type, data: data } ])
        held.empty?
      end
    end
  end
end
