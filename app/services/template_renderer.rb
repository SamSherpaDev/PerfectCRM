# frozen_string_literal: true

# Substitutes {{placeholders}} in template subject lines and bodies.
#
# Context contract (kept a plain Hash on purpose): the mail task and the
# PerfectBook-link task will supply real values later (Client names, Booking
# trip and dates, Invoice amounts and references) without changing this code.
# Keys may be symbols or strings. Supported keys:
#
#   first_name, full_name, trip, departure_dates, balance_due, deposit_due,
#   invoice_number, payment_reference, missing_documents, advisor_name,
#   my_name, signature
#
# Unknown placeholders render as a visible "[missing: name]" marker so a
# half-filled message is never sent silently. Values are substituted raw by
# .render (for plain-text mail); .render_html escapes values so the Turbo
# preview pane stays safe to embed.
class TemplateRenderer
  PLACEHOLDERS = %w[
    first_name full_name trip departure_dates balance_due deposit_due
    invoice_number payment_reference missing_documents advisor_name
    my_name signature
  ].freeze

  PATTERN = /{{\s*([A-Za-z0-9_]+)\s*}}/.freeze

  # Warm sample values for the preview pane and the picker fallback.
  SAMPLE_CONTEXT = {
    "first_name" => "Maya",
    "full_name" => "Maya Gurung",
    "trip" => "Everest Base Camp trek",
    "departure_dates" => "May 4 – May 18, 2027",
    "balance_due" => "$1,850.00",
    "deposit_due" => "$500.00",
    "invoice_number" => "SH-2027-0142",
    "payment_reference" => "SH-0142-MAYA",
    "missing_documents" => "passport copy, insurance certificate",
    "advisor_name" => "Adventure Co.",
    "my_name" => "Sam",
    "signature" => "Sam"
  }.freeze

  def self.placeholders_in(text)
    text.to_s.scan(PATTERN).flatten.uniq
  end

  def self.render(text, context = {})
    substitute(text.to_s, normalize(context)) { |value| value.to_s }
  end

  def self.render_html(text, context = {})
    substitute(ERB::Util.html_escape(text.to_s), normalize(context)) do |value|
      ERB::Util.html_escape(value.to_s)
    end.html_safe # rubocop:disable Rails/OutputSafety
  end

  def self.substitute(text, values)
    text.gsub(PATTERN) do
      name = Regexp.last_match(1)
      if values.key?(name)
        yield values.fetch(name)
      else
        "[missing: #{name}]"
      end
    end
  end
  private_class_method :substitute

  def self.normalize(context)
    normalized = {}
    context.each { |key, value| normalized[key.to_s] = value unless value.nil? }
    normalized
  end
  private_class_method :normalize
end
