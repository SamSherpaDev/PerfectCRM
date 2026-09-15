class Template < ApplicationRecord
  has_many :tasks, dependent: :nullify

  enum :purpose, {
    first_reply: 0,
    itinerary_follow_up: 1,
    deposit_nudge: 2,
    document_request: 3,
    pre_trip_briefing: 4,
    during_trip_checkin: 5,
    review_ask: 6,
    repeat_nudge: 7,
    custom: 8
  }, validate: true

  PURPOSE_LABELS = {
    "first_reply" => "First reply",
    "itinerary_follow_up" => "Itinerary follow-up",
    "deposit_nudge" => "Deposit nudge",
    "document_request" => "Document request",
    "pre_trip_briefing" => "Pre-trip briefing",
    "during_trip_checkin" => "During-trip check-in",
    "review_ask" => "Review ask",
    "repeat_nudge" => "Repeat nudge",
    "custom" => "Custom"
  }.freeze

  validates :name, presence: true
  validates :body, presence: true
  validates :channel, inclusion: { in: %w[email] }

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :ordered, -> { order(:position, :id) }
  scope :for_purpose, ->(purpose) { where(purpose: purpose) }

  before_validation :assign_position, on: :create

  def archived?
    archived_at.present?
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def unarchive!
    update!(archived_at: nil)
  end

  # One-tap use from the picker: counts the insert so dead templates get pruned.
  def record_use!
    increment!(:usage_count)
    touch(:last_used_at)
  end

  def purpose_label
    PURPOSE_LABELS.fetch(purpose)
  end

  # Placeholder names this template needs, subject first, in order.
  def placeholders
    TemplateRenderer.placeholders_in("#{subject}\n#{body}")
  end

  # Rendered subject and body against a plain-hash context (see TemplateRenderer).
  # Operational sends render ONLY the caller's live values: unknown or
  # empty values stay visible as [missing: name] markers, never silent
  # blanks. Sample data appears solely in the labeled editor preview
  # (templates/_preview_contents), never here.
  def rendered(context = {})
    values = context.transform_keys(&:to_s)
    {
      subject: TemplateRenderer.render(subject, values),
      body: TemplateRenderer.render(body, values)
    }
  end

  # Nudge this template one step within its purpose group on the index.
  def move(direction)
    siblings = self.class.active.for_purpose(purpose).ordered.to_a
    fresh = siblings.find { |sibling| sibling.id == id }
    index = siblings.index(fresh)
    return false if index.nil?

    other = if direction == "down"
      index < siblings.length - 1 ? siblings[index + 1] : nil
    else
      index.positive? ? siblings[index - 1] : nil
    end
    return false if other.nil?

    self.class.transaction do
      my_position = fresh.position
      fresh.update!(position: other.position)
      other.update!(position: my_position)
    end
    true
  end

  private

  def assign_position
    # The column default is 0, so treat it as unset on create.
    self.position = (self.class.maximum(:position) || 0) + 1 if position.nil? || position.zero?
  end
end
