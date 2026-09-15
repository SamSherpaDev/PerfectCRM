require "test_helper"

class MailImportPreviewTest < ActiveSupport::TestCase
  test "suggests organizations for shared domains" do
    rows = Mail::ImportPreview.new.build_counts("a@ops.co" => 2, "b@ops.co" => 1, "solo@example.com" => 1)
    by_email = rows.index_by(&:email)
    assert_equal 2, by_email["a@ops.co"].count
    assert_equal "organization", by_email["a@ops.co"].suggested_kind
    assert_equal "organization", by_email["b@ops.co"].suggested_kind
    assert_equal "client", by_email["solo@example.com"].suggested_kind
  end

  test "flags duplicates against existing records" do
    Client.create!(name: "Dup", email: "dup@example.com")
    rows = Mail::ImportPreview.new.build_counts("dup@example.com" => 1)
    assert rows.first.duplicate?
    assert_equal "Dup", rows.first.duplicate_name
  end

  test "public provider domains never suggest organizations" do
    counts = %w[gmail googlemail yahoo hotmail outlook live icloud me aol proton protonmail].flat_map do |provider|
      [ [ "one@#{provider}.com", 1 ], [ "two@#{provider}.com", 1 ] ]
    end.to_h
    rows = Mail::ImportPreview.new.build_counts(counts)
    assert rows.all? { |row| row.suggested_kind == "client" }
  end

end
