# Demo dataset for the first sign-in: a believable small Sherpa Holidays
# world so Today, Inbox, Pipeline, and Quotes look alive.
#
# Load:   DEMO_SEED=1 bin/rails db:seed
# Reload: DEMO_SEED=1 bin/rails db:seed  (idempotent, safe to rerun)
# Wipe:   bin/rails runner 'DemoSeed.wipe!'  (deletes ONLY demo rows,
#         matched by @demo.example.test emails and reserved PerfectBook ids)
#
# Guard: this file does nothing unless DEMO_SEED=1 is set, and refuses to
# run in production. It is never loaded by default.
return unless ENV["DEMO_SEED"] == "1"
raise "DEMO_SEED must never run in production" if Rails.env.production?

require_relative "demo_seed"
DemoSeed.load!
