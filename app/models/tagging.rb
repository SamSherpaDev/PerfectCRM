class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :taggable, polymorphic: true

  validates :tag_id, uniqueness: { scope: %i[taggable_type taggable_id] }

  after_save :refresh_taggable_search
  after_destroy :refresh_taggable_search

  private

  def refresh_taggable_search
    taggable.touch_activity! if taggable.respond_to?(:touch_activity!)
    taggable.sync_fts! if taggable.respond_to?(:sync_fts!)
  rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordNotFound
    nil
  end
end
