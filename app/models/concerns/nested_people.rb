module NestedPeople
  extend ActiveSupport::Concern

  included do
    before_validation :sync_nested_same_person_name
    validate :preserve_linked_people
    before_save :release_reassigned_person_emails
  end

  private

  def sync_nested_same_person_name
    return unless persisted?
    return if respond_to?(:converted?) && (converted? || converted_client_id_in_database.present?) && !allow_converted_name_sync

    old_owner_name = name_in_database.to_s.strip
    return if old_owner_name.blank?

    same_people = association(:people).target.select do |person|
      person.persisted? && !person.marked_for_destruction? &&
        person.name_in_database.to_s.strip.casecmp?(old_owner_name)
    end
    return unless same_people.one?

    person = same_people.first
    if will_save_change_to_name?
      return if name.to_s.strip.blank?

      if !person.will_save_change_to_name?
        person.name = name
        person.skip_name_propagation = true
      elsif person.name.to_s.strip.casecmp?(name.to_s.strip)
        person.skip_name_propagation = true
      end
    elsif person.will_save_change_to_name? && person.name.to_s.strip.present?
      self.name = person.name
      person.skip_name_propagation = true
    end
  end

  def preserve_linked_people
    association(:people).target.each do |person|
      if person.marked_for_destruction? && person.linked_source_history?
        errors.add(:base, "Cannot remove #{person.name}: this person is linked to source history")
      end
    end
  end

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
