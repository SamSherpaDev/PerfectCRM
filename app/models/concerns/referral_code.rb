# Advisor referral code shared by Lead and Client.
#
# The storefront inquiry form sends attribution.referral_code on
# sherpa.inquiry.v2 (a ?ref=CODE landing link, 90-day sh_ref cookie);
# PerfectBook's Contact::REFERRAL_CODE_FORMAT owns the alphabet. Intake
# ignores anything outside the format as if no code was given; the model
# validation below guards hand entry and the console instead.
module ReferralCode
  extend ActiveSupport::Concern

  # Six chars from ABCDEFGHJKMNPQRSTUVWXYZ23456789: spoken aloud and
  # pasted into URLs, so no I, L, O, 0, or 1. Mirrors PerfectBook's
  # Contact::REFERRAL_CODE_FORMAT and the storefront inquiry-form.js.
  REFERRAL_CODE_FORMAT = /\A[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}\z/

  included do
    before_validation :normalize_referral_code
    validates :referral_code, format: { with: REFERRAL_CODE_FORMAT }, allow_nil: true
  end

  private

  def normalize_referral_code
    self.referral_code = referral_code.to_s.strip.upcase.presence
  end
end
