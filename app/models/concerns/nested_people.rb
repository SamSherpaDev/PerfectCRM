module NestedPeople
  extend ActiveSupport::Concern

  included do
    before_validation :sync_nested_same_person_name
    validate :preserve_linked_people
    before_save :release_reassigned_person_emails
  end

  attr_reader :name_identity_person_ids

  private

  def sync_nested_same_person_name
    @name_identity_person_ids = nil
    return unless persisted?

    people = association(:people).target
    return unless will_save_change_to_name? || people.any?(&:will_save_change_to_name?)
    return if respond_to?(:converted?) && (converted? || converted_client_id_in_database.present?) && !allow_converted_name_sync

    rows = association(:people).scope.where.not(id: people.select(&:marked_for_destruction?).map(&:id)).pluck(:id, :name)
    new_people = people.select { |person| person.new_record? && !person.marked_for_destruction? }
    people_count = rows.size + new_people.size
    namesake_ids = rows.select { |_id, person_name| person_name.to_s.strip.casecmp?(name_in_database.to_s.strip) }.map(&:first)
    sole = people.find { |person| person.persisted? && person.id == namesake_ids.first } if namesake_ids.one?
    renamed_sole = sole if sole&.will_save_change_to_name? && sole.name.to_s.strip.present?

    if !will_save_change_to_name?
      return unless renamed_sole

      self.name = renamed_sole.name
      renamed_sole.skip_name_propagation = true
      @name_identity_person_ids = namesake_ids
    elsif renamed_sole && renamed_sole.name.to_s.strip.casecmp?(name.to_s.strip)
      renamed_sole.skip_name_propagation = true
      @name_identity_person_ids = namesake_ids
    elsif people_count.zero? || (people_count == 1 && (namesake_ids.one? || new_people.any? { |person| person.name.to_s.strip.casecmp?(name.to_s.strip) }))
      @name_identity_person_ids = namesake_ids
      if sole && !sole.will_save_change_to_name? && sole.name != name
        sole.name = name
        sole.skip_name_propagation = true
      end
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
