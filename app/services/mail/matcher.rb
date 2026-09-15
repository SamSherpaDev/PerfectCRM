# Matches an inbound address to an existing record before anything is filed.
# Exact email wins on client, person, lead, or organization; a remembered
# EmailIdentity from a past triage confirmation wins next. Nothing is ever
# created silently: unknown senders go to triage as suggested clients.
module Mail
  class Matcher
    Result = Struct.new(:linkable, :via, keyword_init: true)

    def self.call(addresses, **kwargs)
      new.call(addresses, **kwargs)
    end

    def call(addresses, exclude_mailbox: true)
      Array(addresses).each do |address|
        normalized = ::EmailIdentity.normalized(address)
        next if normalized.blank?
        next if exclude_mailbox && Mail.mailbox_aliases.include?(normalized)

        if (identity = ::EmailIdentity.find_for(normalized))
          return Result.new(linkable: identity.linkable, via: "identity") if identity.linkable.present?
          return Result.new(linkable: nil, via: "ignored") if identity.ignored?
        end

        if (client = ::Client.find_by(email: normalized))
          return Result.new(linkable: client, via: "client")
        end
        if (person = ::Person.find_by(email: normalized))
          owner = person.client || person.lead
          return Result.new(linkable: owner, via: "person") if owner
        end
        if (lead = ::Lead.find_by(email: normalized))
          return Result.new(linkable: lead, via: "lead")
        end
        if (organization = ::Organization.find_by(email: normalized))
          return Result.new(linkable: organization, via: "organization")
        end
      end
      Result.new(linkable: nil, via: "unknown")
    end
  end
end
