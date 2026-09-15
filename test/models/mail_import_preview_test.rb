require "test_helper"

class MailImportPreviewTest < ActiveSupport::TestCase
  test "groups senders and suggests organizations for shared domains" do
    messages = [
      { raw: "From: a@ops.co\r\nTo: info@sherpaholidays.com\r\nSubject: x\r\nMessage-ID: <1@t>\r\n\r\nb" },
      { raw: "From: b@ops.co\r\nTo: info@sherpaholidays.com\r\nSubject: x\r\nMessage-ID: <2@t>\r\n\r\nb" },
      { raw: "From: solo@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: x\r\nMessage-ID: <3@t>\r\n\r\nb" }
    ]
    rows = Mail::ImportPreview.build(messages)
    by_email = rows.index_by(&:email)
    assert_equal "organization", by_email["a@ops.co"].suggested_kind
    assert_equal "organization", by_email["b@ops.co"].suggested_kind
    assert_equal "client", by_email["solo@example.com"].suggested_kind
  end

  test "flags duplicates against existing records" do
    Client.create!(name: "Dup", email: "dup@example.com")
    messages = [ { raw: "From: dup@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: x\r\nMessage-ID: <d@t>\r\n\r\nb" } ]
    rows = Mail::ImportPreview.build(messages)
    assert rows.first.duplicate?
    assert_equal "Dup", rows.first.duplicate_name
  end

  test "skips personal mail in the preview" do
    messages = [ { raw: "From: friend@gmail.com\r\nTo: captain@gmail.com\r\nSubject: x\r\nMessage-ID: <p@t>\r\n\r\nb" } ]
    assert_empty Mail::ImportPreview.build(messages)
  end

  test "captain choices override the suggestion" do
    messages = [ { raw: "From: solo@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: x\r\nMessage-ID: <s@t>\r\n\r\nb" } ]
    rows = Mail::ImportPreview.build(messages, choices: { "solo@example.com" => "organization" })
    assert_equal "organization", rows.first.suggested_kind
  end
  test "outbound and remembered addresses share matching semantics" do
    client = Client.create!(name: "Remembered", email: "original@example.com")
    EmailIdentity.remember!("alternate@example.com", linkable: client)
    messages = [ { raw: "From: info@sherpaholidays.com\r\nTo: alternate@example.com\r\n\r\nHello" } ]
    row = Mail::ImportPreview.build(messages).first
    assert_equal "alternate@example.com", row.email
    assert_equal 1, row.count
    assert row.duplicate?
    assert_equal client.name, row.duplicate_name
  end

  test "public provider domains never suggest organizations" do
    counts = %w[gmail googlemail yahoo hotmail outlook live icloud me aol proton protonmail].flat_map do |provider|
      [ [ "one@#{provider}.com", 1 ], [ "two@#{provider}.com", 1 ] ]
    end.to_h
    rows = Mail::ImportPreview.new.build_counts(counts)
    assert rows.all? { |row| row.suggested_kind == "client" }
  end

end
