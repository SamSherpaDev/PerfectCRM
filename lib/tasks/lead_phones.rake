namespace :leads do
  desc "Recover blank inquiry/contact phones from encrypted phone_raw (counts only, safe to repeat)"
  task backfill_phones: :environment do
    puts JSON.generate(Leads::PhoneBackfill.call)
  end
end
