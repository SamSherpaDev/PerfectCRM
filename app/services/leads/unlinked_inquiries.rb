require "uri"

module Leads
  # A local, bounded check of imported mail. Website copies left in triage can
  # match their inquiry by reference or submission, never just a sender's email.
  class UnlinkedInquiries
    LOOKBACK = 7.days
    RECEIVED_AT = "COALESCE(messages.inbound_received_at, messages.sent_at, messages.created_at)"
    WEBSITE = /\b(?:new (?:website |trip )?inquiry|website inquiry|contact form|new customer message|(?:perfect)?crm fallback)\b/i
    HEADERS = %w[list-unsubscribe auto-submitted precedence x-autoreply x-autorespond x-ms-exchange-inbox-rules-loop].freeze
    AUTOMATIC = /\A(?:automatic reply|auto(?:matic)?[- ]response|out of (?:the )?office|undeliverable|delivery (?:status notification|failure)|mail delivery failed)\b/i
    # Notification, social, ad, and security gateway domains whose mail is not a traveler inquiry.
    PLATFORM_DOMAINS = %w[
      apple.com
      buffer.com
      cloud-protect.net
      facebook.com
      facebookmail.com
      google.com
      instagram.com
      link.com
      meta.com
      simplefin.org
      tripadvisor.com
    ].freeze
    PUBLIC_EMAIL_PROVIDERS = %w[
      gmail googlemail yahoo hotmail outlook live icloud me aol proton protonmail
    ].freeze
    AUTOMATED_SENDER = /(?:\A|[._-])(?:do[._-]?not[._-]?reply|no[._-]?reply|notifications?|alerts?|bounces?|auto(?:mated|[._-]?confirm)|news(?:letters?)?|updates?|digest|receipts?|billing|invoices?|orders?|security|quarantine|system)(?:\z|[+._-])/i
    NEWSLETTER = /\b(?:unsubscribe|manage\s+(?:your\s+)?(?:email\s+|subscription\s+)?preferences|email\s+preferences|update\s+(?:your\s+)?preferences)\b/i
    RECEIPT_SUBJECT = /\b(?:receipt|invoice|payment\s+(?:confirmation|received|failed)|order\s+confirmation|billing\s+statement)\b/i
    Candidate = Data.define(:message, :references, :external_refs)

    def initialize(now: Time.current)
      @now = now
    end

    def messages(unalerted: false)
      scope = Message.inbound.joins(:conversation).where(conversations: { ignored: false })
        .where.not(conversation_id: Conversation.inquiry_linked.select(:id))
        .where("#{RECEIVED_AT} BETWEEN ? AND ?", @now - LOOKBACK, @now)
      scope = scope.where(inquiry_alert_attempted_at: nil) if unalerted
      candidates = scope.preload(:conversation).order(Arel.sql("#{RECEIVED_AT} ASC, messages.id ASC"))
        .filter_map { |message| candidate(message) }
      return [] if candidates.empty?

      references = Lead.where(reference: candidates.flat_map(&:references)).pluck(:reference).to_set
      external_refs = Lead.where(external_ref: candidates.flat_map(&:external_refs)).pluck(:external_ref).to_set
      candidates.filter_map do |item|
        matched = item.references.any? { |ref| references.include?(ref) } ||
          item.external_refs.any? { |ref| external_refs.include?(ref) }
        item.message unless matched
      end
    end

    private

    def candidate(message)
      from = EmailIdentity.normalized(message.from_address)
      return if message.subject.to_s.match?(AUTOMATIC) ||
        from.match?(/\A(?:mailer-daemon|postmaster)@/i)

      body = body_text(message)
      text = "#{message.subject}\n#{body}"
      website = text.match?(WEBSITE)
      unless website
        return if from.blank? || own_sender?(from) || known_business_contact?(message, from) ||
          automated_or_platform?(message, from, text)
      end

      Candidate.new(message: message,
        references: website ? body.scan(/\bReference:\s*(SH-[a-z0-9]+)\b/i).flatten.map(&:upcase) : [],
        external_refs: website ? body.scan(/\bsubmission[ _-]?id["']?\s*[:=]\s*["']?([a-z0-9_-]{1,64})/i)
          .flatten.map { |id| "website_form:#{id}" } : [])
    end

    def own_sender?(from)
      from == ::Mail.mailbox_address || from.match?(/@(?:[^@]+\.)?sherpaholidays\.com\z/i)
    end

    def known_business_contact?(message, from)
      return true if message.conversation.linkable_type == "Organization"

      match = ::Mail::Matcher.call([ from ])
      return true if match.via == "ignored" || match.via == "person" || match.linkable.is_a?(Organization)
      return true if Organization.where("lower(email) = ?", from).exists? ||
        Person.where("lower(email) = ?", from).exists?

      domain = from.split("@", 2).last.to_s
      organization_domain?(domain)
    end

    def organization_domain?(domain)
      host = domain.to_s.downcase
      return false if host.blank? || PUBLIC_EMAIL_PROVIDERS.include?(host.split(".").first)

      organization_domains.any? { |entry| host == entry || host.end_with?(".#{entry}") }
    end

    def organization_domains
      @organization_domains ||= Organization.pluck(:email, :website).flat_map do |email, website|
        mail_domain = email.to_s.split("@", 2).last.to_s.downcase.presence
        site_host = begin
          URI.parse(website.to_s).host.to_s.downcase.sub(/\Awww\./, "").presence if website.present?
        rescue URI::InvalidURIError
          nil
        end
        [ mail_domain, site_host ].compact
      end.reject { |dom| PUBLIC_EMAIL_PROVIDERS.include?(dom.split(".").first) }.to_set
    end

    def automated_or_platform?(message, from, text)
      local, domain = from.split("@", 2)
      return true if local.to_s.match?(AUTOMATED_SENDER) || platform_domain?(domain)
      return true if automated_headers?(message.inquiry_headers)
      return true if message.subject.to_s.match?(RECEIPT_SUBJECT)

      text.match?(NEWSLETTER) || message.html_body.to_s.match?(/\bunsubscribe\b/i)
    end

    def platform_domain?(domain)
      host = domain.to_s.downcase
      PLATFORM_DOMAINS.any? { |entry| host == entry || host.end_with?(".#{entry}") }
    end

    def automated_headers?(raw_headers)
      headers = raw_headers || {}
      return true if Array(headers["list-unsubscribe"]).any?(&:present?)
      return true if Array(headers["auto-submitted"]).any? { |value| value.present? && !value.strip.casecmp?("no") }
      return true if Array(headers["precedence"]).any? { |value| value.match?(/\b(?:bulk|list|junk)\b/i) }

      %w[x-autoreply x-autorespond x-ms-exchange-inbox-rules-loop].any? do |name|
        Array(headers[name]).any?(&:present?)
      end
    end

    def body_text(message)
      return message.text_body if message.text_body.present?

      fragment = Nokogiri::HTML.fragment(message.html_body.to_s)
      fragment.css("script, style").remove
      fragment.css("br").each { |node| node.replace("\n") }
      fragment.css("p, div, tr, li").each { |node| node.add_next_sibling("\n") }
      fragment.text.tr("\u00a0", " ")
    end
  end
end
