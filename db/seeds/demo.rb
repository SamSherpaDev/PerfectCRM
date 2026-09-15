# Demo dataset for the first sign-in: a believable small Sherpa Holidays
# world so Today, Inbox, Pipeline, and Quotes look alive.
#
# Usage and cleanup: docs/getting-started.md, "Demo data".
# Keep this opt-in guard: db:prepare also loads seeds on first deployment.
return unless ENV["DEMO_SEED"] == "1"
raise "DEMO_SEED must never run in production" if Rails.env.production?

require_relative "demo_seed"
DemoSeed.load!
