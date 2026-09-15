require "test_helper"

class DocumentUploaderTest < ActiveSupport::TestCase
  test "raises NotImplemented with a clear message until PerfectBook ships the endpoint" do
    attachment = Struct.new(:filename).new("passport.pdf")
    error = assert_raises(NotImplementedError) do
      PerfectBook::DocumentUploader.upload(attachment: attachment, booking_id: "1")
    end
    assert_match(/pb-document-intake/, error.message)
    assert_match(/POST \/api\/v1\/contacts/, error.message)
  end
end
