namespace :sources do
  desc "Dry-run inventory and deterministic source batches (OUTPUT required; no writes to records)"
  task dry_run: :environment do
    SourceBackfill.dry_run!(ENV.fetch("OUTPUT"))
    puts "Dry-run written. Review each CSV, then approve its SHA256 before applying. No records changed."
  end

  desc "Apply one reviewed source batch (BATCH, REVIEWER, APPROVED_SHA256 required)"
  task apply: :environment do
    result = SourceBackfill.apply!(ENV.fetch("BATCH"), reviewer: ENV.fetch("REVIEWER"), approved_digest: ENV.fetch("APPROVED_SHA256"))
    puts JSON.pretty_generate(result)
  end
end
