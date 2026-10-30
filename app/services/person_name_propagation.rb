# frozen_string_literal: true

# Propagates a name change across every linked PerfectCRM record that still
# carries the old name, updates open follow-ups, unsent drafts, draft quotes,
# and open scheduled calls, and appends one timeline entry without rewriting
# sent messages, delivered quotes, or past activity history.
class PersonNamePropagation
  def self.call(record, old_name:, new_name:)
    new(record, old_name: old_name, new_name: new_name).call
  end

  def initialize(record, old_name:, new_name:)
    @record = record
    @old_name = old_name.to_s.strip
    @new_name = new_name.to_s.strip
    @skipped = 0
  end

  def call
    return if @old_name.blank? || @new_name.blank? || @old_name == @new_name

    if @record.is_a?(Organization)
      propagate_organization
    else
      propagate_person_or_owner
    end
    Current.name_change_skips = Current.name_change_skips.to_i + @skipped if @skipped.positive?
  end

  private

  def propagate_organization
    update_open_tasks([ @record ])
    update_unsent_drafts([ @record ])
    record_activity_event(@record)
  end

  def propagate_person_or_owner
    seed_people, seed_clients, seed_leads, person_emails = gather_seeds
    if @record.is_a?(Person) && namesake_shares_owner?(seed_people)
      update_people(seed_people)
    else
      propagate_to_family(seed_people, seed_clients, seed_leads, person_emails)
    end

    event_subject = @record.is_a?(Person) ? @record.owner : @record
    record_activity_event(event_subject) if event_subject
  end

  def propagate_to_family(seed_people, seed_clients, seed_leads, person_emails)
    family_clients, family_leads = expand_owner_family(seed_clients, seed_leads, person_emails)
    target_people = select_target_people(seed_people, family_clients, family_leads, person_emails)

    update_clients(family_clients.select { |client| same_name?(client.name, @old_name) })
    update_leads(family_leads.select { |lead| same_name?(lead.name, @old_name) })
    update_people(target_people)

    affected_owners = (family_clients + family_leads + target_people.filter_map(&:owner)).uniq
    update_open_tasks(affected_owners)
    update_unsent_drafts(affected_owners)
    update_draft_quotes(affected_owners)
    update_open_scheduled_calls(affected_owners)
  end

  def namesake_shares_owner?(seed_people)
    Person.where(client_id: seed_people.filter_map(&:client_id))
      .or(Person.where(lead_id: seed_people.filter_map(&:lead_id)))
      .where.not(id: seed_people.map(&:id))
      .any? { |person| same_name?(person.name, @old_name) }
  end

  def sole_namesakes(people)
    people.select { |person| same_name?(person.name, @old_name) }
      .group_by { |person| [ person.client_id, person.lead_id ] }
      .filter_map { |_owner, namesakes| namesakes.first if namesakes.one? }
  end

  def gather_seeds
    if @record.is_a?(Person)
      seed_people = expand_origin_people([ @record ])
      seed_clients = Client.where(id: seed_people.filter_map(&:client_id).uniq).to_a
      seed_leads = Lead.where(id: seed_people.filter_map(&:lead_id).uniq).to_a
      emails = seed_people.filter_map { |person| normalize_email(person.email) }.uniq
      [ seed_people, seed_clients, seed_leads, emails ]
    else
      own_people = @record.people.reload.to_a
      matching_people = sole_namesakes(own_people) + own_people.select { |person| same_name?(person.name, @new_name) }
      seed_people = expand_origin_people(matching_people)
      seed_clients = @record.is_a?(Client) ? [ @record ] : []
      seed_leads = @record.is_a?(Lead) ? [ @record ] : []
      seed_clients |= Client.where(id: seed_people.filter_map(&:client_id).uniq).to_a
      seed_leads |= Lead.where(id: seed_people.filter_map(&:lead_id).uniq).to_a
      emails = ([ @record.email ] + seed_people.map(&:email)).filter_map { |email| normalize_email(email) }.uniq
      [ seed_people, seed_clients, seed_leads, emails ]
    end
  end

  def expand_origin_people(initial_people)
    people_by_id = initial_people.compact.index_by(&:id)
    loop do
      ids = people_by_id.keys
      break if ids.empty?

      origin_ids = people_by_id.values.filter_map(&:origin_person_id).uniq - ids
      linked = Person.where(origin_person_id: ids).where.not(id: ids).to_a
      linked.concat(Person.where(id: origin_ids).to_a) if origin_ids.any?
      linked.select! { |person| same_name?(person.name, @old_name) }
      break if linked.empty?

      linked.each { |person| people_by_id[person.id] = person }
    end
    people_by_id.values
  end

  def expand_owner_family(seed_clients, seed_leads, person_emails)
    clients_by_id = seed_clients.compact.index_by(&:id)
    leads_by_id = seed_leads.compact.index_by(&:id)

    loop do
      added = false
      client_ids = clients_by_id.keys
      lead_ids = leads_by_id.keys
      pb_ids = (clients_by_id.values.filter_map(&:perfectbook_contact_id) +
        leads_by_id.values.filter_map(&:perfectbook_contact_id)).uniq
      owner_emails = (clients_by_id.values.filter_map { |c| normalize_email(c.email) } +
        leads_by_id.values.filter_map { |l| normalize_email(l.email) } +
        person_emails).uniq

      new_leads = []
      if client_ids.any?
        new_leads.concat(Lead.where(converted_client_id: client_ids).where.not(id: lead_ids).to_a)
        new_leads.concat(Lead.where(existing_client_id: client_ids).where.not(id: lead_ids).to_a)
      end
      origin_lead_ids = (clients_by_id.values.filter_map(&:origin_lead_id) +
        leads_by_id.values.filter_map(&:origin_lead_id)).uniq - lead_ids
      new_leads.concat(Lead.where(id: origin_lead_ids).to_a) if origin_lead_ids.any?
      new_leads.concat(Lead.where(origin_lead_id: lead_ids).where.not(id: lead_ids).to_a) if lead_ids.any?
      new_leads.concat(Lead.where(perfectbook_contact_id: pb_ids).where.not(id: lead_ids).to_a) if pb_ids.any?
      new_leads.concat(Lead.where("lower(email) IN (?)", owner_emails).where.not(id: lead_ids).to_a) if owner_emails.any?

      new_leads.uniq(&:id).each do |lead|
        next if leads_by_id.key?(lead.id) || !same_name?(lead.name, @old_name)

        leads_by_id[lead.id] = lead
        added = true
      end

      lead_ids = leads_by_id.keys
      new_clients = []
      linked_client_ids = (leads_by_id.values.filter_map(&:converted_client_id) +
        leads_by_id.values.filter_map(&:existing_client_id)).uniq - client_ids
      new_clients.concat(Client.where(id: linked_client_ids).to_a) if linked_client_ids.any?
      new_clients.concat(Client.where(origin_lead_id: lead_ids).where.not(id: client_ids).to_a) if lead_ids.any?
      new_clients.concat(Client.where(perfectbook_contact_id: pb_ids).where.not(id: client_ids).to_a) if pb_ids.any?
      new_clients.concat(Client.where("lower(email) IN (?)", owner_emails).where.not(id: client_ids).to_a) if owner_emails.any?

      new_clients.uniq(&:id).each do |client|
        next if clients_by_id.key?(client.id) || !same_name?(client.name, @old_name)

        clients_by_id[client.id] = client
        added = true
      end

      break unless added
    end

    [ clients_by_id.values, leads_by_id.values ]
  end

  def select_target_people(seed_people, family_clients, family_leads, person_emails)
    candidates = seed_people.dup
    client_ids = family_clients.map(&:id)
    lead_ids = family_leads.map(&:id)

    candidates.concat(sole_namesakes(Person.where(client_id: client_ids))) if client_ids.any?
    candidates.concat(sole_namesakes(Person.where(lead_id: lead_ids))) if lead_ids.any?
    if person_emails.any?
      candidates.concat(Person.where("lower(email) IN (?)", person_emails).select { |person| same_name?(person.name, @old_name) })
    end

    expand_origin_people(candidates.uniq(&:id))
  end

  def update_clients(clients)
    clients.each do |client|
      next if client == @record || client.name == @new_name

      client.skip_name_propagation = true
      save_linked(client) { client.update!(name: @new_name) }
    ensure
      client.skip_name_propagation = false if client
    end
  end

  def update_leads(leads)
    leads.each do |lead|
      next if lead == @record || lead.name == @new_name

      lead.skip_name_propagation = true
      lead.allow_converted_name_sync = true
      save_linked(lead) { lead.update!(name: @new_name) }
    ensure
      if lead
        lead.skip_name_propagation = false
        lead.allow_converted_name_sync = false
      end
    end
  end

  def update_people(people)
    people.each do |person|
      next if person == @record || person.name == @new_name

      person.skip_name_propagation = true
      save_linked(person) { person.update!(name: @new_name) }
    ensure
      person.skip_name_propagation = false if person
    end
  end

  def update_open_tasks(owners)
    return if owners.empty?

    Task.open.where(subject: owners).find_each do |task|
      allow_first = first_name_replaceable_for?(task.subject)
      new_title = replace_name_in_text(task.title, allow_first_name: allow_first)
      new_notes = replace_name_in_text(task.notes, allow_first_name: allow_first)
      if new_title != task.title || new_notes != task.notes
        save_linked(task) { task.update!(title: new_title, notes: new_notes) }
      end
    end
  end

  def update_unsent_drafts(owners)
    return if owners.empty?

    conversation_ids = Conversation.where(linkable: owners).select(:id)
    scope = Draft.where(owner: owners).or(Draft.where(conversation_id: conversation_ids))
    scope.find_each do |draft|
      allow_first = first_name_replaceable_for?(draft.owner)
      attrs = {
        to_addrs: replace_name_in_text(draft.to_addrs, allow_first_name: false),
        cc_addrs: replace_name_in_text(draft.cc_addrs, allow_first_name: false),
        bcc_addrs: replace_name_in_text(draft.bcc_addrs, allow_first_name: false),
        subject: replace_name_in_text(draft.subject, allow_first_name: allow_first),
        body: replace_name_in_text(draft.body, allow_first_name: allow_first)
      }
      draft.update_columns(attrs) if attrs.any? { |key, value| draft.public_send(key) != value }
    end
  end

  def update_draft_quotes(owners)
    client_ids = owners.select { |o| o.is_a?(Client) }.map(&:id)
    lead_ids = owners.select { |o| o.is_a?(Lead) }.map(&:id)
    return if client_ids.empty? && lead_ids.empty?

    clauses = []
    clauses << Quote.where(client_id: client_ids) if client_ids.any?
    clauses << Quote.where(lead_id: lead_ids) if lead_ids.any?
    scope = clauses.reduce(:or).where(status: "draft", terms_bundle: nil)

    scope.find_each do |quote|
      changed = false
      details = quote.disclosure_details.is_a?(Hash) ? quote.disclosure_details.deep_dup : nil
      if details && details["travelers"].present?
        updated_travelers = replace_name_in_text(details["travelers"], allow_first_name: false)
        if updated_travelers != details["travelers"]
          details["travelers"] = updated_travelers
          quote.disclosure_details = details
          changed = true
        end
      end
      if quote.notes.present?
        updated_notes = replace_name_in_text(quote.notes, allow_first_name: false)
        if updated_notes != quote.notes
          quote.notes = updated_notes
          changed = true
        end
      end
      save_linked(quote) { quote.save! } if changed
    end
  end

  def update_open_scheduled_calls(owners)
    lead_ids = owners.select { |o| o.is_a?(Lead) }.map(&:id)
    return if lead_ids.empty?

    ScheduledCall.visible.scheduled.where(lead_id: lead_ids).find_each do |call|
      next if call.notes.blank?

      allow_first = first_name_replaceable_for?(call.lead)
      updated_notes = replace_name_in_text(call.notes, allow_first_name: allow_first)
      save_linked(call) { call.update!(notes: updated_notes) } if updated_notes != call.notes
    end
  end

  def save_linked(record)
    yield
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => error
    @skipped += 1
    Rails.logger.warn("[name_change] #{record.class.name} #{record.id} kept the old name: #{error.message}")
  end

  def record_activity_event(subject)
    metadata = {
      "old_name" => @old_name,
      "new_name" => @new_name,
      "actor" => Current.user_email.presence || "manual"
    }
    metadata["person_id"] = @record.id if @record.is_a?(Person)
    subject.activity_events.create!(
      kind: "name_change",
      summary: "Name changed from #{@old_name} to #{@new_name}",
      occurred_at: Time.current,
      metadata: metadata
    )
  end

  def replace_name_in_text(text, allow_first_name: false)
    return text if text.blank?

    full_names = [ @old_name, @new_name ].sort_by { |name| -name.length }.map { |name| Regexp.escape(name) }
    updated = text.gsub(/(?<![\w.@+-])(?:#{full_names.join("|")})(?![\w.@+-])/i) do |match|
      match.casecmp?(@old_name) ? @new_name : match
    end
    return updated unless allow_first_name

    salutation = /^([ \t]*(?i:hi|hello|hey|dear)[ \t]+)#{Regexp.escape(old_first_name)}(?![\w.@+-])/
    updated.gsub(salutation) { "#{Regexp.last_match(1)}#{new_first_name}" }
  end

  def first_name_replaceable_for?(owner)
    return false unless (owner.is_a?(Client) || owner.is_a?(Lead)) && owner.kind != "company"
    return false unless @old_name.split.size >= 2
    return false if old_first_name.length < 2 || new_first_name.blank? || old_first_name == new_first_name

    ([ owner.name ] + owner.people.reload.map(&:name)).none? do |name|
      name.to_s.split.first.to_s.casecmp?(old_first_name)
    end
  end

  def old_first_name
    @old_first_name ||= @old_name.split.first.to_s
  end

  def new_first_name
    @new_first_name ||= @new_name.split.first.to_s
  end

  def same_name?(left, right)
    left.to_s.strip.present? && left.to_s.strip.casecmp?(right.to_s.strip)
  end

  def normalize_email(email)
    email.to_s.strip.downcase.presence
  end
end
