require "test_helper"
require_relative "../../db/migrate/20261030180658_add_signature_logo_checksums_to_settings"

class SignatureLogoChecksumsMigrationTest < ActiveSupport::TestCase
  teardown { Setting.reset_column_information }

  test "backfills the attached signature logo checksum on a database that already has a logo" do
    logo = "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + [ 120, 40 ].pack("NN") + "\x08\x02\x00\x00\x00migration-logo".b
    Setting.current.signature_logo.attach(io: StringIO.new(logo), filename: "signature-logo.png", content_type: "image/png")
    migration = AddSignatureLogoChecksumsToSettings.new

    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:down)
      migration.migrate(:up)
    end
    Setting.reset_column_information

    assert_equal [ Digest::MD5.base64digest(logo) ], Setting.current.signature_logo_checksums
  end
end
