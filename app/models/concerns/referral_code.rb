# Referral intake contract: docs/leads-intake.md.
module ReferralCode
  extend ActiveSupport::Concern

  # Avoid ambiguous characters in spoken codes and URLs. Mirrors PerfectBook's
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
