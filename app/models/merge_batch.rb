# frozen_string_literal: true

# A group-departure preview consumed by GroupSendsController for delivery.
#
# Malformed recipient lines are RETAINED with their line numbers and shown
# as errors: the batch refuses to present itself as complete until they are
# fixed or removed, so a mistyped address can never silently drop a traveler.
class MergeBatch
  Recipient = Data.define(:name, :email)
  RecipientError = Data.define(:line_number, :line, :problem)
  Message = Data.define(:name, :email, :subject, :body, :booking_owner_name)

  attr_reader :template, :recipients, :messages, :errors

  def self.build(template:, recipient_lines:, context_for: nil)
    recipients, errors = parse_recipients_with_errors(recipient_lines, reject_not_interested: true)
    messages = recipients.map do |recipient|
      context = { "first_name" => first_name_for(recipient.name), "full_name" => recipient.name }
      context.merge!(context_for.call(recipient)) if context_for
      rendered = template.rendered(context)
      Message.new(name: recipient.name, email: context["recipient_email"] || recipient.email,
        subject: rendered[:subject], body: rendered[:body], booking_owner_name: context["booking_owner_name"])
    end
    new(template: template, recipients: recipients, messages: messages, errors: errors)
  end

  # One recipient per line: "Maya Gurung <maya@example.com>" or "maya@example.com".
  def self.parse_recipients(lines)
    parse_recipients_with_errors(lines).first
  end

  # Same parse, but malformed lines come back as RecipientError entries with
  # 1-based line numbers instead of vanishing.
  def self.parse_recipients_with_errors(lines, reject_not_interested: false)
    recipients = []
    errors = []
    lines.to_s.lines.each_with_index do |raw, index|
      line = raw.strip
      next if line.empty?

      match = line.match(/\A([^<>]*)\s*<([^<>]+)>\z/)
      email = match ? match[2] : line
      name = match ? match[1].strip.presence : nil
      if email.match?(URI::MailTo::EMAIL_REGEXP) && !email.match?(/[,;\s]/)
        if reject_not_interested && not_interested_lead_email?(email)
          errors << RecipientError.new(line_number: index + 1, line: line,
            problem: "Marked not interested - do not contact.")
        else
          recipients << Recipient.new(name: name, email: email)
        end
      else
        errors << RecipientError.new(line_number: index + 1, line: line,
          problem: "Needs one email address: “Name <email>” or just “email”.")
      end
    end
    [ recipients, errors ]
  end

  def self.not_interested_lead_email?(email)
    normalized = email.to_s.strip.downcase
    return false if normalized.blank?
    return false if Client.where(email: normalized).exists? ||
      Person.where("lower(email) = ?", normalized).where.not(client_id: nil).exists?

    scope = Lead.not_interested
    person_lead_ids = Person.where("lower(email) = ?", normalized).where.not(lead_id: nil).select(:lead_id)
    history = scope.where(<<~SQL, email: normalized)
      EXISTS (SELECT 1 FROM json_each(email_redirects) WHERE key = :email OR value = :email)
      OR EXISTS (SELECT 1 FROM json_each(ambiguous_emails) WHERE value = :email)
    SQL
    scope.where(email: normalized).or(scope.where(id: person_lead_ids)).or(history).exists?
  end

  def self.first_name_for(name)
    name.to_s.split.first.to_s
  end
  private_class_method :first_name_for

  def initialize(template:, recipients:, messages:, errors: [])
    @template = template
    @recipients = recipients
    @messages = messages
    @errors = errors
  end

  def size
    recipients.size
  end

  # Complete means sendable: at least one good recipient and no broken lines.
  def complete?
    errors.empty? && recipients.any?
  end
end
