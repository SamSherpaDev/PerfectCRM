require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class OutboundSensitiveUploadsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    @client = Client.create!(name: "Maya", email: "maya@example.com")
    sign_in
  end

  test "send draft and validation recovery refuse sensitive files before storage" do
    examples = [
      [ "passport.pdf", "application/pdf", "passport bytes" ],
      [ "visa.jpg", "image/jpeg", "visa bytes" ],
      [ "insurance.txt", "text/plain", "insurance bytes" ],
      [ "traveler-id.png", "image/png", "ID bytes" ],
      [ "date-of-birth.txt", "text/plain", "birth bytes" ],
      [ "document.txt", "application/x-passport", "typed bytes" ],
      [ "document.pdf", "application/pdf", pdf_with_title("Passport copy") ],
      [ "correspondence.eml", "application/octet-stream", enclosed_email("passport.pdf", "application/pdf", "passport bytes") ],
      [ "correspondence.dat", "message/rfc822", enclosed_email("passport.pdf", "application/pdf", "passport bytes") ],
      [ "forward.eml", "message/rfc822", enclosed_email("inner.eml", "message/rfc822", enclosed_email("passport.pdf", "application/pdf", "passport bytes")) ]
    ]
    examples.each do |filename, type, bytes|
      %i[send draft recovery].each do |action|
        Tempfile.create("outbound-upload") do |file|
          file.binmode
          file.write(bytes)
          file.rewind
          upload = Rack::Test::UploadedFile.new(file.path, type, true, original_filename: filename)
          fields = { to: @client.email, subject: "Hello", body: action == :recovery ? "  " : "See attached", files: [ upload ] }
          assert_no_difference([ "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count", "Message.count" ]) do
            if action == :draft
              patch client_draft_path(@client), params: { message: fields }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
            else
              post client_messages_path(@client), params: { message: fields }
              follow_redirect!
            end
          end
          assert_response :success
          if action == :draft
            assert_select "turbo-stream[target='draft-status']", text: /Sensitive documents live in PerfectBook - attach it there/
          else
            assert_select "#draft-attachments [role=alert]", text: "Sensitive documents live in PerfectBook - attach it there"
          end
        end
      end
    end
  end

  test "ordinary attached emails remain intact" do
    bytes = enclosed_email("itinerary.txt", "text/plain", "Meet at the airport")
    Tempfile.create("ordinary-email") do |file|
      file.binmode
      file.write(bytes)
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, "message/rfc822", true, original_filename: "correspondence.eml")
      assert_difference("Message.count", 1) do
        post client_messages_path(@client), params: { message: { to: @client.email, subject: "Itinerary", body: "See attached", files: [ upload ] } }
      end
      assert_equal "correspondence.eml", Message.last.files.first.filename.to_s
      assert_equal bytes, Message.last.files.first.download
    end
  end

  private

  def enclosed_email(filename, content_type, bytes)
    mail = ::Mail.new
    mail.from = "sender@example.com"
    mail.to = "info@sherpaholidays.com"
    mail.subject = "Correspondence"
    mail.body = "See enclosed"
    mail.attachments[filename] = { mime_type: content_type, content: bytes }
    mail.encoded
  end

  def pdf_with_title(title)
    encoded_title = "FEFF" + title.encode("UTF-16BE").unpack1("H*")
    objects = [ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>", "<< /Title <#{encoded_title}> >>" ]
    pdf = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |object, index|
      offset = pdf.bytesize
      pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 4\n0000000000 65535 f \n"
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size 4 /Root 1 0 R /Info 3 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end
end
