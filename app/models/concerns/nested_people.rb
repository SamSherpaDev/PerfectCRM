module NestedPeople
  extend ActiveSupport::Concern

  def self.same_identity?(owner_name, people_names)
    people_names.size <= 1 && people_names.all? { |name| name.to_s.strip.casecmp?(owner_name.to_s.strip) }
  end

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
    return unless will_save_change_to_name? || association(:people).target.any?(&:will_save_change_to_name?)
    return if respond_to?(:converted?) && (converted? || converted_client_id_in_database.present?) && !allow_converted_name_sync

    rows = association(:people).scope.pluck(:id, :name)
    return unless NestedPeople.same_identity?(name_in_database, rows.map(&:last))

    @name_identity_person_ids = rows.map(&:first)
    person = association(:people).target.find { |candidate| candidate.id == @name_identity_person_ids.first }
    return if person.nil? || person.marked_for_destruction?

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
