module Leads
  # A local, bounded check of imported mail. Website copies left in triage can
  # match their inquiry by reference or submission, never just a sender's email.
  class UnlinkedInquiries
    LOOKBACK = 7.days
    RECEIVED_AT = "COALESCE(messages.inbound_received_at, messages.sent_at, messages.created_at)"
    WEBSITE = /\b(?:new (?:website |trip )?inquiry|website inquiry|contact form|new customer message|(?:perfect)?crm fallback)\b/i
    HEADERS = %w[list-unsubscribe auto-submitted precedence x-autoreply x-autorespond x-ms-exchange-inbox-rules-loop].freeze
    AUTOMATIC = /\A(?:automatic reply|auto(?:matic)?[- ]response|out of (?:the )?office|undeliverable|delivery (?:status notification|failure)|mail delivery failed)\b/i
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
      return if message.subject.to_s.match?(AUTOMATIC) ||
        message.from_address.to_s.match?(/\A(?:mailer-daemon|postmaster)@/i)

      body = body_text(message)
      text = "#{message.subject}\n#{body}"
      website = text.match?(WEBSITE)
      unless website
        return if message.conversation.linkable_type == "Organization" ||
          ::Mail::Matcher.call([ message.from_address ]).linkable.is_a?(Organization)
        return if message.from_address.to_s.match?(/\Ano[._-]?reply(?:[+._-][^@]*)?@/i)

        headers = message.inquiry_headers || {}
        return if Array(headers["list-unsubscribe"]).any?(&:present?)
        return if Array(headers["auto-submitted"]).any? { |value| value.present? && !value.strip.casecmp?("no") }
        return if Array(headers["precedence"]).any? { |value| value.match?(/\b(?:bulk|list|junk)\b/i) }
        return if %w[x-autoreply x-autorespond x-ms-exchange-inbox-rules-loop].any? do |name|
          Array(headers[name]).any?(&:present?)
        end
      end

      Candidate.new(message: message,
        references: website ? body.scan(/\bReference:\s*(SH-[a-z0-9]+)\b/i).flatten.map(&:upcase) : [],
        external_refs: website ? body.scan(/\bsubmission[ _-]?id["']?\s*[:=]\s*["']?([a-z0-9_-]{1,64})/i)
          .flatten.map { |id| "website_form:#{id}" } : [])
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
