# frozen_string_literal: true

# A preview of one template rendered for several recipients at once — the
# group-departure merge. No sending happens here; the mail task will consume
# this object (each entry becomes one personal send) when delivery lands.
#
# Recipients are plain name/email pairs for now; the bookings task will feed
# richer per-recipient contexts (trip, dates, balances) through +context_for+.
class MergeBatch
  Recipient = Data.define(:name, :email)
  Message = Data.define(:name, :email, :subject, :body)

  attr_reader :template, :recipients, :messages

  def self.build(template:, recipient_lines:, context_for: nil)
    recipients = parse_recipients(recipient_lines)
    messages = recipients.map do |recipient|
      context = { "first_name" => first_name_for(recipient.name), "full_name" => recipient.name }
      context.merge!(context_for.call(recipient)) if context_for
      rendered = template.rendered(context)
      Message.new(name: recipient.name, email: recipient.email,
        subject: rendered[:subject], body: rendered[:body])
    end
    new(template: template, recipients: recipients, messages: messages)
  end

  # One recipient per line: "Maya Gurung <maya@example.com>" or "maya@example.com".
  def self.parse_recipients(lines)
    lines.to_s.lines.filter_map do |line|
      line = line.strip
      next if line.empty?

      if (match = line.match(/^(.*?)\s*<([^<>@\s]+@[^<>@\s]+)>\s*$/))
        name = match[1].strip
        Recipient.new(name: name.presence || match[2], email: match[2])
      elsif line.match?(/\A[^<>\s]+@[^<>\s]+\z/)
        Recipient.new(name: line, email: line)
      end
    end
  end

  def self.first_name_for(name)
    name.to_s.split.first.to_s
  end
  private_class_method :first_name_for

  def initialize(template:, recipients:, messages:)
    @template = template
    @recipients = recipients
    @messages = messages
  end

  def size
    recipients.size
  end
end
