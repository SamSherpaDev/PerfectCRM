# frozen_string_literal: true

module Outbound
  module OwnerLookup
    class Conflict < StandardError; end

    def self.for_email(email)
      normalized = email.to_s.strip.downcase
      return nil if normalized.blank?

      candidates = [ Client.all, Lead.open ].flat_map do |scope|
        person_ids = Person.where("lower(email) = ?", normalized)
          .select("#{scope.klass.model_name.singular}_id")
        history = scope.where(<<~SQL, email: normalized)
          EXISTS (SELECT 1 FROM json_each(email_redirects) WHERE key = :email)
          OR EXISTS (SELECT 1 FROM json_each(ambiguous_emails) WHERE value = :email)
        SQL
        scope.where(email: normalized).or(scope.where(id: person_ids)).or(history).limit(2).to_a
      end
      if candidates.many?
        raise Conflict, "#{normalized} matches multiple records. Choose an unambiguous current address or send from the intended record."
      end

      candidates.first
    end
  end
end
