module SourceAnswers
  module_function

  def record!(record, choice:, detail: nil, method: "call", reason: nil, evidence: nil, referrals: {})
    record.with_lock do
      record.source_collection_method = method
      record.source_correction_reason = reason
      record.source_evidence_reference = evidence
      record.assign_attributes(referrals.slice("referred_by_client_id", "referred_by_person_id"))
      record.source_choice = choice
      record.reported_source_detail = detail.to_s.strip.presence if %w[answered unsure].include?(record.source_answer_state)
      if method == "website_form" && record.source_confirmed_at.present? && record.changed?
        record.errors.add(:base, "Source already confirmed by the team")
        raise ActiveRecord::RecordInvalid, record
      end
      # Explicit confirmation of an unchanged provisional answer is also audited.
      if method != "website_form" && !record.source_missing? && record.source_confirmed_at.nil?
        record.source_confirmed_at = Time.current
      end
      record.save! if record.changed?
      record.activity_events.where(kind: "source_answer").order(:id).last
    end
  end
end
