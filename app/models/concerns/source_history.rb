# Source testimony is independent of observed clicks and compatibility source.
module SourceHistory
  extend ActiveSupport::Concern

  QUESTION_VERSION = "how-heard-v1".freeze
  ANSWERS = {
    "personal_referral" => "A friend or family member",
    "search" => "Google or another search engine",
    "facebook" => "Facebook", "instagram" => "Instagram", "youtube" => "YouTube",
    "tiktok" => "TikTok", "pinterest" => "Pinterest",
    "event" => "A travel show or event", "advisor_partner" => "A travel advisor or another business",
    "maps_reviews" => "Google Maps or Tripadvisor", "email_marketing" => "An email from SherpaHolidays",
    "existing_relationship" => "I already knew Sam, Gyalgin or SherpaHolidays",
    "other" => "Somewhere else", "unsure" => "I don't remember"
  }.freeze
  CHANNELS = %w[website_form phone email social_dm trade_show in_person other].freeze
  STATES = %w[not_asked answered unsure declined].freeze
  ANSWER_FIELDS = %w[reported_source_code reported_source_detail source_answer_state source_confirmed_at].freeze
  COPY_FIELDS = (ANSWER_FIELDS + %w[capture_channel is_test referred_by_client_id referred_by_person_id]).freeze

  included do
    belongs_to :origin_lead, class_name: "Lead", optional: true
    belongs_to :referred_by_client, class_name: "Client", optional: true
    belongs_to :referred_by_person, class_name: "Person", optional: true
    attr_accessor :source_collection_method, :source_correction_reason, :source_evidence_reference
    normalizes :capture_channel, :reported_source_detail, with: ->(value) { value.to_s.strip.presence }
    validates :capture_channel, inclusion: { in: CHANNELS }, allow_nil: true
    validates :source_answer_state, inclusion: { in: STATES }
    validates :reported_source_code, inclusion: { in: ANSWERS.keys }, allow_nil: true
    validates :reported_source_detail, length: { maximum: 240 }
    validate :consistent_source_answer
    validate :valid_personal_referral
    validate :known_source_links
    before_save :stamp_source_confirmation
    after_save :audit_source_answer
    after_save :audit_personal_referral
  end

  # Single select includes internal states without making them discovery sources.
  def source_choice
    reported_source_code.presence || source_answer_state
  end

  def source_choice=(value)
    value = value.to_s.presence || "not_asked"
    self.source_answer_state = value == "unsure" ? "unsure" : (ANSWERS.key?(value) ? "answered" : value)
    self.reported_source_code = ANSWERS.key?(value) ? value : nil
    self.reported_source_detail = nil unless %w[answered unsure].include?(source_answer_state)
  end

  def source_missing?
    source_answer_state == "not_asked"
  end

  def source_label
    ANSWERS[reported_source_code] || { "not_asked" => "Not asked yet", "declined" => "Declined to answer" }[source_answer_state]
  end

  def source_copy_attributes
    attributes.slice(*COPY_FIELDS)
  end

  private

  def consistent_source_answer
    valid = case source_answer_state
    when "answered" then reported_source_code.present? && reported_source_code != "unsure"
    when "unsure" then reported_source_code == "unsure"
    when "declined", "not_asked" then reported_source_code.nil? && reported_source_detail.blank?
    end
    errors.add(:source_answer_state, "does not match the answer") unless valid
    if persisted? && ANSWER_FIELDS.first(3).any? { |field| will_save_change_to_attribute?(field) } &&
        source_answer_state_in_database != "not_asked" && source_collection_method != "website_form" && source_correction_reason.blank?
      errors.add(:source_correction_reason, "is required to correct an answer")
    end
  end

  def known_source_links
    %i[origin_lead referred_by_client referred_by_person].each do |name|
      errors.add(name, "must be an existing record") if public_send("#{name}_id").present? && public_send(name).nil?
    end
  end

  def valid_personal_referral
    if referred_by_client && referred_by_person
      errors.add(:base, "Choose one personal referrer")
    end
    cursor = referred_by_client || referred_by_person
    seen = []
    while cursor
      key = [ cursor.class.name, cursor.id ]
      if cursor == self || seen.include?(key)
        errors.add(:base, "Personal referrals cannot link to themselves or form a cycle")
        break
      end
      seen << key
      cursor = cursor.referred_by_client || cursor.referred_by_person
    end
  end

  def stamp_source_confirmation
    return if source_collection_method == "conversion"
    changed = ANSWER_FIELDS.first(3).any? { |field| will_save_change_to_attribute?(field) }
    if changed
      self.source_confirmed_at = nil
      self.source_confirmed_at = Time.current if Current.user_email.present? && source_collection_method != "website_form" && !source_missing?
    end
  end

  def audit_personal_referral
    return if source_collection_method == "conversion"
    changes = saved_changes.slice("referred_by_client_id", "referred_by_person_id")
    return if changes.empty?
    ActivityEvent.create!(subject: self, kind: "source_referral", summary: "Personal referral link reviewed", occurred_at: Time.current,
      metadata: { "changes" => changes, "recorded_by" => Current.user_email.presence || "system" })
  end

  def audit_source_answer
    return if source_collection_method == "conversion"
    changes = saved_changes.slice(*ANSWER_FIELDS)
    return if changes.empty? || (source_missing? && changes.keys == [ "source_answer_state" ])

    ActivityEvent.create!(subject: self, kind: "source_answer", summary: "Heard about us: #{source_label}", occurred_at: Time.current,
      metadata: {
        "question_version" => QUESTION_VERSION, "answer_code" => reported_source_code,
        "detail" => reported_source_detail, "state" => source_answer_state,
        "asked_at" => Time.current.iso8601, "recorded_by" => Current.user_email.presence || (source_collection_method == "website_form" ? "website_form" : "system"),
        "collection_method" => source_collection_method.presence || "manual",
        "prior_answer" => changes.transform_values(&:first), "correction_reason" => source_correction_reason.to_s.first(240),
        "evidence_reference" => source_evidence_reference.to_s.first(120)
      })
  end
end
