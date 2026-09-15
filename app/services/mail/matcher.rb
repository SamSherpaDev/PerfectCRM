# Matching and triage policy: see README.md, "Mail".
module Mail
  class Matcher
    Result = Struct.new(:linkable, :via, keyword_init: true)

    def self.call(addresses)
      new.call(addresses)
    end

    def call(addresses)
      Array(addresses).each do |address|
        normalized = ::EmailIdentity.normalized(address)
        next if normalized.blank?
        next if normalized == Mail.mailbox_address

        if (identity = ::EmailIdentity.find_for(normalized))
          return Result.new(linkable: self.class.current_owner(identity.linkable), via: "identity") if identity.linkable.present?
          return Result.new(linkable: nil, via: "ignored") if identity.ignored?
        end

        if (client = ::Client.find_by(email: normalized))
          return Result.new(linkable: client, via: "client")
        end
        if (person = ::Person.find_by(email: normalized))
          owner = person.client || person.lead
          return Result.new(linkable: self.class.current_owner(owner), via: "person") if owner
        end
        if (lead = ::Lead.find_by(email: normalized))
          return Result.new(linkable: self.class.current_owner(lead), via: "lead")
        end
        if (organization = ::Organization.find_by(email: normalized))
          return Result.new(linkable: organization, via: "organization")
        end
      end
      Result.new(linkable: nil, via: "unknown")
    end

    def self.current_owner(record)
      record.is_a?(::Lead) && record.converted? ? record.converted_client : record
    end
  end
end
