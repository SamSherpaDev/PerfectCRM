module NestedPeople
  extend ActiveSupport::Concern

  included do
    before_save :release_reassigned_person_emails
  end

  private

  # Release old emails inside the owner's save transaction before autosave
  # assigns replacements, so the unique index is safe in any person order.
  def release_reassigned_person_emails
    return unless persisted?

    ids = association(:people).target.select do |person|
      person.persisted? && person.will_save_change_to_email?
    end.map(&:id)
    people.where(id: ids).update_all(email: nil) if ids.any?
  end
end
