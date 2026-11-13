namespace :backup do
  desc "Print the Drive attachment backup allowlist: blob keys only (docs/operations.md, \"Attachments backup\")"
  task attachment_manifest: :environment do
    $stdout.write AttachmentBackup.manifest
  end

  desc "Print Drive attachment backup counts and bytes only, never a key or filename"
  task attachment_summary: :environment do
    puts JSON.generate(AttachmentBackup.summary)
  end
end
