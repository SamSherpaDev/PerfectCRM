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

    def build_counts(grouped)
      domains = Hash.new(0)
      grouped.each_key { |email| domains[email.split("@").last] += 1 }

      rows = grouped.map do |email, count|
        duplicate_name = duplicate_name_for(email)
        suggested = suggest_kind(email, domains)
        Row.new(email: email, count: count, suggested_kind: suggested,
          duplicate: duplicate_name.present?, duplicate_name: duplicate_name)
      end
      rows.sort_by { |row| [ -row.count, row.email ] }
    end

    private

    def duplicate_name_for(email)
      match = Matcher.call([ email ])
      match.via == "ignored" ? "Ignored sender" : match.linkable&.name
    end

    def suggest_kind(email, domains)
      domain = email.split("@").last.to_s.downcase
      public_domains = %w[gmail googlemail yahoo hotmail outlook live icloud me aol proton protonmail]
      return "client" if public_domains.include?(domain.split(".").first)
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
