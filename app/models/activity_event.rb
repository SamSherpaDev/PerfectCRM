# Append-only timeline entries. Later tasks (mail, tasks, quotes, pipeline,
# PerfectBook cards) write their own kinds here; nothing updates or deletes.
# Kind "automation" is reserved for n8n and Panda AI machine events; kind
# "conversion" marks a lead becoming a client.
class ActivityEvent < ApplicationRecord
  belongs_to :subject, polymorphic: true

  serialize :metadata, coder: JSON

  validates :kind, presence: true
  validates :summary, presence: true
  validates :occurred_at, presence: true

  after_create :touch_subject

  scope :newest_first, -> { order(occurred_at: :desc, id: :desc) }

  def readonly?
    persisted?
  end

  private

  def touch_subject
    subject.touch_activity! if subject.respond_to?(:touch_activity!)
  rescue ActiveRecord::RecordNotFound, NoMethodError
    nil
  end
end
