namespace :leads do
  desc "Recover blank inquiry/contact phones from encrypted phone_raw (counts only, safe to repeat)"
  task backfill_phones: :environment do
    puts JSON.generate(Leads::PhoneBackfill.call)
  end

  desc "Fill missing source/attribution from submission_page.landing_url when last_touch was unavailable (idempotent)"
  task backfill_attribution: :environment do
    puts JSON.generate(Leads::Acquisition.backfill_unavailable_touches!)
  end
end
