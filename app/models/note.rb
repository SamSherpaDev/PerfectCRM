class Note < ApplicationRecord
  belongs_to :notable, polymorphic: true
  belongs_to :author, class_name: "User", optional: true

  validates :body, presence: true, length: { maximum: 10_000 }

  after_create :bump_counters
  after_destroy :unbump_counters
  after_save :refresh_notable_search
  after_destroy :refresh_notable_search

  scope :newest_first, -> { order(created_at: :desc) }

  private

  def bump_counters
    if notable.is_a?(Client)
      Client.increment_counter(:notes_count, notable.id)
      notable.touch_activity!
      record_timeline_event
    elsif notable.is_a?(Lead)
      Lead.increment_counter(:notes_count, notable.id)
      notable.touch_activity!
      record_timeline_event
    elsif notable.respond_to?(:touch_activity!)
      notable.touch_activity!
      record_timeline_event
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def unbump_counters
    if notable.is_a?(Client) && notable.notes_count.to_i.positive?
      Client.decrement_counter(:notes_count, notable.id)
    elsif notable.is_a?(Lead) && notable.notes_count.to_i.positive?
      Lead.decrement_counter(:notes_count, notable.id)
    end
    notable.touch_activity! if notable.respond_to?(:touch_activity!)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def record_timeline_event
    ActivityEvent.create!(
      subject: notable,
      kind: "note",
      summary: "Note added",
      occurred_at: created_at || Time.current,
      metadata: { "note_id" => id }
    )
  rescue ActiveRecord::RecordInvalid
    nil
  end

  def refresh_notable_search
    notable.sync_fts! if notable.respond_to?(:sync_fts!)
  rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordNotFound
    nil
  end
end
