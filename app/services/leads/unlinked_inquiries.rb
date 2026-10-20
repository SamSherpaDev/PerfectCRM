require "uri"

module Leads
  # A local, bounded check of imported mail. Only unlinked website-form copies
  # (notification or fallback emails for website submissions, sent by our own
  # systems or the form's relay) are candidates; ordinary inbound emails stay in
  # the inbox as threads, however they are laid out. Website copies left in
  # triage can match their inquiry by reference or submission; a shared email
  # alone only matches a lead still waiting in New.
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
    # Website-form relays that send form notifications from a personal-looking address.
    WEBSITE_RELAY_DOMAINS = %w[shopify.com shopifyemail.com].freeze
    AUTOMATED_SENDER = /(?:\A|[._-])(?:do[._-]?not[._-]?reply|no[._-]?reply|notifications?|alerts?|bounces?|auto(?:mated|[._-]?confirm)|news(?:letters?)?|updates?|digest|receipts?|billing|invoices?|orders?|security|quarantine|system)(?:\z|[+._-])/i
    BLANK_VALUES = %w[— – - n/a na none null unknown].freeze
    Candidate = Data.define(:message, :name, :explicit_name, :email, :phone_raw, :trip,
      :inquiry_message, :received_at, :references, :external_refs)

    def self.own_safety_net_lead?(lead, message)
      lead.is_a?(Lead) && lead.safety_net_inquiry? &&
        lead.metadata["safety_net_message_id"].to_i == message.id
    end

    # Our own mailbox, a website relay, or a no-reply/platform sender: never
    # the person an inquiry is from, so never the address a reply goes to.
    def self.relay_sender?(from)
      address = EmailIdentity.normalized(from)
      address.present? && (own_sender?(address) || automated_sender_address?(address))
    end

    def self.own_sender?(from)
      from == ::Mail.mailbox_address || from.match?(/@(?:[^@]+\.)?sherpaholidays\.com\z/i)
    end

    def self.automated_sender_address?(from)
      local, domain = from.split("@", 2)
      local.to_s.match?(AUTOMATED_SENDER) || domain_in?(domain, PLATFORM_DOMAINS)
    end

    # Our own mailbox or domain, the form's relay, or a no-reply/notification
    # address: only these send website-form copies.
    def self.website_form_sender?(from)
      local, domain = from.split("@", 2)
      own_sender?(from) || local.to_s.match?(AUTOMATED_SENDER) || domain_in?(domain, WEBSITE_RELAY_DOMAINS)
    end

    def self.domain_in?(domain, entries)
      host = domain.to_s.downcase
      entries.any? { |entry| host == entry || host.end_with?(".#{entry}") }
    end

    def initialize(now: Time.current)
      @now = now
    end

    def messages(unalerted: false)
      listed = unlinked_conversations.or(Conversation.where(linkable_type: "Lead", linkable_id: untriaged_safety_net_leads.select(:id)))
      items = candidates_scope(listed, unalerted: unalerted).filter_map { |message| candidate(message) }
      return [] if items.empty?

      references = Lead.where(reference: items.flat_map(&:references)).pluck(:reference, :id)
      external_refs = Lead.where(external_ref: items.flat_map(&:external_refs)).pluck(:external_ref, :id)
      items.filter_map do |item|
        own_id = own_safety_net_lead_id(item.message)
        matched = item.references.any? { |ref| references.any? { |r, id| r == ref && id != own_id } } ||
          item.external_refs.any? { |ref| external_refs.any? { |r, id| r == ref && id != own_id } } ||
          item.external_refs.any? { |ref| (m = ::Leads.find_by_merged_submission_id(ref.delete_prefix("website_form:"))) && m.id != own_id }
        item.message unless matched
      end
    end

    # Only unlinked threads are resolved: a thread already on a record never moves.
    def resolve!
      candidates_scope(unlinked_conversations).filter_map { |message| candidate(message) }.each do |item|
        resolve_candidate!(item)
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.error("[inquiry safety net] message #{item.message.id} not resolved: #{error.class}: #{error.message.truncate(200)}")
      end
    end

    private

    def unlinked_conversations
      Conversation.where(linkable_type: nil)
    end

    def candidates_scope(conversations, unalerted: false)
      scope = Message.inbound.joins(:conversation).where(conversations: { ignored: false })
        .where(conversation_id: conversations.select(:id))
        .where("#{RECEIVED_AT} BETWEEN ? AND ?", @now - LOOKBACK, @now)
      scope = scope.where(inquiry_alert_attempted_at: nil) if unalerted
      scope.preload(conversation: :linkable).order(Arel.sql("#{RECEIVED_AT} ASC, messages.id ASC"))
    end

    def untriaged_safety_net_leads
      Lead.in_new_tab.where(source: "website_form")
        .where("CASE WHEN json_valid(leads.metadata) THEN json_extract(leads.metadata, '$.inquiry_safety_net') END = 1")
    end

    def own_safety_net_lead_id(message)
      lead = message.conversation&.linkable
      lead.id if self.class.own_safety_net_lead?(lead, message)
    end

    def resolve_candidate!(item)
      Lead.transaction do
        conversation = Conversation.find(item.message.conversation_id)
        next if conversation.linkable_type || conversation.ignored?

        existing = matching_existing_lead(item)
        conversation.update!(linkable: existing ? existing.converted_client || existing : create_safety_net_lead!(item))
      end
    end

    def matching_existing_lead(item)
      (Lead.where(reference: item.references).order(:id).first if item.references.any?) ||
        (Lead.where(external_ref: item.external_refs).order(:id).first if item.external_refs.any?) ||
        item.external_refs.lazy.filter_map { |ref| ::Leads.find_by_merged_submission_id(ref.delete_prefix("website_form:")) }.first ||
        (Lead.in_new_tab.where("lower(email) = ?", item.email)
          .order(Arel.sql("COALESCE(received_at, created_at) DESC, id DESC")).first if item.email.present?)
    end

    def create_safety_net_lead!(item)
      existing_client = Client.find_by("lower(email) = ?", item.email) if item.email.present?

      external_ref = item.external_refs.first
      external_ref = nil if external_ref.present? && Lead.exists?(external_ref: external_ref)
      reference = item.references.first
      reference = nil if reference.present? && Lead.exists?(reference: reference)

      lead = Lead.new(
        name: item.explicit_name.presence || existing_client&.name.presence || item.name,
        email: item.email,
        phone_raw: item.phone_raw,
        phone: (Leads::Phone.normalize(item.phone_raw) if item.phone_raw.present?),
        trip_title: item.trip,
        trip_interest: item.trip,
        message: item.inquiry_message,
        received_at: item.received_at,
        last_touch_at: item.received_at,
        stage_changed_at: item.received_at,
        source: "website_form",
        status: "new",
        external_ref: external_ref,
        reference: reference,
        existing_client: existing_client,
        metadata: { "inquiry_safety_net" => true, "safety_net_message_id" => item.message.id }
      )
      lead.save!
      lead
    end

    def candidate(message)
      if message.conversation.linkable_type.present?
        return unless self.class.own_safety_net_lead?(message.conversation.linkable, message)
      end

      from = EmailIdentity.normalized(message.from_address)
      return if message.subject.to_s.match?(AUTOMATIC) ||
        from.match?(/\A(?:mailer-daemon|postmaster)@/i) ||
        !self.class.website_form_sender?(from) ||
        reply_message?(message)

      body = body_text(message)
      text = "#{message.subject}\n#{body}"
      return unless text.match?(WEBSITE)

      references = body.scan(/\bReference:\s*(SH-[a-z0-9]+)\b/i).flatten.map(&:upcase)
      external_refs = body.scan(/\bsubmission[ _-]?id["']?\s*[:=]\s*["']?([a-z0-9_-]{1,64})/i)
        .flatten.map { |id| "website_form:#{id}" }
      parsed = extract_fields(message, body)
      return unless website_form_fields?(body, parsed, references: references, external_refs: external_refs)

      Candidate.new(
        message: message,
        name: parsed[:name],
        explicit_name: parsed[:explicit_name],
        email: parsed[:email],
        phone_raw: parsed[:phone_raw],
        trip: parsed[:trip],
        inquiry_message: parsed[:inquiry_message],
        received_at: message.inbound_received_at || message.sent_at || message.created_at,
        references: references,
        external_refs: external_refs
      )
    end

    def website_form_fields?(body, parsed, references:, external_refs:)
      return true if references.any? || external_refs.any?
      return false if parsed[:email].blank?

      parsed[:explicit_name].present? ||
        body.match?(/^[ \t]*(?:has in mind|trip(?:\s+interest|\s+title|\s+name)?|message|placement|source|open in perfectcrm)\s*:/im) ||
        body.match?(/"(?:name|trip|message)"\s*:/i)
    end

    def extract_fields(message, body)
      email = extract_email(body)
      explicit_name = extract_explicit_name(message, body)
      fallback_name = display_name_for(email) || clean_field(message.subject) || "Website inquiry"
      phone_raw = clean_field(
        labeled_value(body, /(?:phone(?:\s+number)?|tel(?:ephone)?|mobile)/i) ||
        body[/"phone(?:_raw)?"\s*:\s*"([^"]+)"/i, 1]
      )
      trip = extract_trip(message, body)
      inquiry_message = extract_inquiry_message(body)

      {
        name: (explicit_name || fallback_name).truncate(120),
        explicit_name: explicit_name&.truncate(120),
        email: email,
        phone_raw: phone_raw,
        trip: trip,
        inquiry_message: inquiry_message
      }
    end

    def extract_email(body)
      raw = labeled_value(body, /e-?mail(?:\s+address)?/i) ||
        body[/"email"\s*:\s*"([^"]+)"/i, 1]
      candidate_email = ::Mail.extract_addresses(raw.to_s).first || EmailIdentity.normalized(raw)
      candidate_email if candidate_email.present? && candidate_email.length <= 254 &&
        candidate_email.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def extract_explicit_name(message, body)
      labeled = clean_field(
        labeled_value(body, /(?:full\s+|contact\s+|visitor\s+|customer\s+)?name/i) ||
        body[/"name"\s*:\s*"([^"]+)"/i, 1]
      )
      return labeled if labeled.present?

      clean_field(message.subject.to_s[/\bnew (?:website |trip )?inquiry from\s+([^:\r\n]+)/i, 1])
    end

    def extract_trip(message, body)
      raw = labeled_value(body, /(?:has in mind|trip(?:\s+interest|\s+title|\s+name)?|interested in)/i)
      raw = message.subject.to_s[/\bnew (?:website |trip )?inquiry from\s+[^:\r\n]+:\s*(.+)\z/i, 1] if raw.blank?
      clean_field(raw, extra_blanks: [ "not sure yet" ])&.truncate(160)
    end

    def extract_inquiry_message(body)
      if (match = body.match(/^[ \t]*message\s*:\s*\r?\n?(.*)/im))
        section = match[1].to_s
        section = section.split(/^[ \t]*(?:reference|source|placement|page|open in perfectcrm|submission[ _-]?id|"submission_id"|flagged for a check)\b/im).first.to_s
        clean_field(section)&.truncate(4000)
      elsif !body.match?(/^[ \t]*(?:name|e-?mail|phone|has in mind|reference|submission[ _-]?id|"submission_id")\s*[:=]/im)
        clean_field(body)&.truncate(4000)
      end
    end

    def labeled_value(body, label_pattern)
      body[/^[ \t]*#{label_pattern.source}\s*:\s*([^\r\n]+)/im, 1]
    end

    def clean_field(value, extra_blanks: [])
      text = value.to_s.strip
      return nil if text.blank?
      return nil if (BLANK_VALUES + extra_blanks).include?(text.downcase)

      text
    end

    def display_name_for(email)
      return nil if email.blank?

      email.split("@").first.to_s.split(/[._\-+]/).map(&:capitalize).join(" ").presence || email
    end

    def reply_message?(message)
      message.in_reply_to.present? ||
        message.references_text.present? ||
        message.subject.to_s.match?(/\A\s*(?:re|fw|fwd)\s*:/i) ||
        reply_in_our_conversation?(message)
    end

    def reply_in_our_conversation?(message)
      cutoff = first_outbound(conversation_id: message.conversation_id)
      return true if cutoff && (cutoff <=> [ message.inbound_received_at || message.sent_at || message.created_at, message.id ]).negative?

      refs = "#{message.in_reply_to} #{message.references_text}".scan(/[^\s<>]+@[^\s<>]+/).uniq
      refs.any? && first_outbound(message_id: refs).present?
    end

    def first_outbound(conditions)
      @first_outbound ||= {}
      @first_outbound.fetch(conditions) do
        @first_outbound[conditions] = Message.outbound.where(conditions)
          .where.not(id: Message.automatic_replies.select(:id))
          .pluck(:sent_at, :inbound_received_at, :created_at, :id, :inquiry_headers)
          .reject { |*, headers| automated_headers?(headers) }
          .map { |sent_at, received_at, created_at, id, _| [ sent_at || received_at || created_at, id ] }.min
      end
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
      fragment.css("p, div, tr, li, h1, h2, h3, h4, h5, h6").each { |node| node.add_next_sibling("\n") }
      fragment.text.tr("\u00a0", " ")
    end
  end
end
