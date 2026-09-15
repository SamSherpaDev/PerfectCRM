# Builds the import preview: how many messages fall in scope and which
# distinct senders would become clients versus organizations.
#
# Heuristics (captain-flippable per row):
# - a sender domain shared by several addresses, or matching a PerfectBook
#   partner contact, suggests an organization;
# - single addresses suggest clients;
# - addresses already on a client, lead, person, or organization show as
#   duplicates before commit.
module Mail
  class ImportPreview
    Row = Struct.new(:email, :count, :suggested_kind, :duplicate, :duplicate_name, keyword_init: true) do
      def duplicate?
        !!duplicate
      end
    end

    def self.build(messages, choices: {})
      new.build(messages, choices: choices)
    end

    def build(messages, choices: {})
      grouped = Hash.new(0)
      Array(messages).each do |item|
        parsed = item.is_a?(Mail::Ingester::Parsed) ? item : Mail::Ingester.parse_raw(item[:raw] || item["raw"].to_s)
        senders = Array(parsed.from_addresses).reject { |value| Mail.mailbox_aliases.include?(value) }
        # Import respects the same info@ rule: skip mail with no mailbox trace.
        headers = { "from" => parsed.from_addresses, "to" => parsed.to_addresses, "cc" => parsed.cc_addresses }
        next unless Mail.keeps?(headers)

        sender = senders.first.to_s.downcase.strip
        next if sender.blank?

        grouped[sender] += 1
      end
      domains = Hash.new(0)
      grouped.each_key { |email| domains[email.split("@").last] += 1 }

      rows = grouped.map do |email, count|
        duplicate_name = duplicate_name_for(email)
        suggested = suggest_kind(email, domains)
        override = choices[email] || choices[email.downcase]
        kind = override.presence || suggested
        Row.new(email: email, count: count, suggested_kind: kind,
          duplicate: duplicate_name.present?, duplicate_name: duplicate_name)
      end
      rows.sort_by { |row| [ -row.count, row.email ] }
    end

    private

    def duplicate_name_for(email)
      if (client = ::Client.find_by(email: email))
        return client.name
      end
      if (person = ::Person.find_by(email: email))
        return (person.client || person.lead)&.name || person.name
      end
      if (lead = ::Lead.find_by(email: email))
        return lead.name
      end
      if (organization = ::Organization.find_by(email: email))
        return organization.name
      end
      nil
    end

    def suggest_kind(email, domains)
      domain = email.split("@").last.to_s.downcase
      return "organization" if domains[domain].to_i > 1
      return "organization" if perfectbook_partner?(email, domain)

      "client"
    end

    def perfectbook_partner?(email, domain)
      scope = ::PerfectBook::Contact.where(kind: %w[advisor partner vendor])
      return true if scope.where("lower(email) = ?", email).exists?

      domain_suffix = "@#{domain}"
      scope.where("lower(email) LIKE ?", "%#{domain_suffix}").exists?
    rescue StandardError
      false
    end
  end
end
