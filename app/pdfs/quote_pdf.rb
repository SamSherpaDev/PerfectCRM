# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Washi-styled quote PDF attached to the quote email: cream page, ink text,
# Matches the spirit of PerfectBook's invoice PDF (same paper, same accent).
class QuotePdf
  INK = "14110E"
  MUTED = "5A5550"
  OCHRE = "C96F1A"
  RULE = "E4DCC8"

  def initialize(quote, accept_url:)
    @quote = quote
    @accept_url = accept_url
  end

  def render
    Prawn::Document.new(page_size: "A4", margin: [ 48, 48, 56, 48 ]) do |pdf|
      build(pdf)
    end.render
  end

  private

  def build(pdf)
    directory = Rails.root.join("app/assets/fonts/quote")
    pdf.font_families.update(
      "NotoSans" => { normal: directory.join("NotoSans-Regular.ttf"), bold: directory.join("NotoSans-Bold.ttf") },
      "Devanagari" => { normal: directory.join("NotoSansDevanagari-Regular.ttf"), bold: directory.join("NotoSansDevanagari-Regular.ttf") },
      "Symbols" => { normal: directory.join("NotoSansSymbols2-Regular.ttf"), bold: directory.join("NotoSansSymbols2-Regular.ttf") }
    )
    pdf.font "NotoSans"
    pdf.fallback_fonts = [ "Devanagari", "Symbols" ]
    header(pdf)
    pdf.stroke_color RULE
    pdf.stroke_horizontal_rule
    pdf.move_down 18
    title_block(pdf)
    pdf.move_down 14
    lines_table(pdf)
    pdf.move_down 12
    totals(pdf)
    pdf.move_down 14
    notes_block(pdf)
    pdf.move_down 10
    accept_block(pdf)
    pdf.move_down 18
    footer(pdf)
  end

  def header(pdf)
    pdf.fill_color OCHRE
    pdf.text "Sherpa Holidays", size: 11, style: :bold
    pdf.fill_color MUTED
    pdf.text "Family-run Himalayan adventure travel · info@sherpaholidays.com", size: 8
    pdf.move_down 10
    pdf.fill_color INK
  end

  def title_block(pdf)
    pdf.text "Quote #{@quote.reference}", size: 24
    pdf.move_down 4
    pdf.fill_color MUTED
    pdf.text "Prepared for #{@quote.owner_name}", size: 11
    pdf.move_down 2
    details = []
    details << @quote.trip_name if @quote.trip_name.present?
    details << @quote.departure_label if @quote.departure_label.present?
    if @quote.departure_start_on && @quote.departure_end_on
      details << "#{@quote.departure_start_on.strftime('%-d %b %Y')} – #{@quote.departure_end_on.strftime('%-d %b %Y')}"
    end
    details << "#{@quote.party_size} guests" if @quote.party_size.present?
    pdf.text details.join(" · "), size: 10 unless details.empty?
    pdf.text "Valid until #{@quote.valid_until.strftime('%-d %B %Y')}", size: 10 if @quote.valid_until
    pdf.fill_color INK
  end

  def lines_table(pdf)
    rows = [ [ "Description", "Qty", "Each", "Total" ] ] + @quote.lines.map do |line|
      [ line.description, line.quantity.to_s, money(line.unit_minor), money(line.total_minor) ]
    end
    pdf.table(rows, header: true, width: pdf.bounds.width) do |table|
      table.row(0).font_style = :bold
      table.row(0).text_color = MUTED
      table.columns(1..3).align = :right
      table.cells.borders = [ :bottom ]
      table.cells.border_color = RULE
      table.cells.padding = [ 6, 4, 6, 4 ]
    end
  end

  def totals(pdf)
    pdf.text "Total #{money(@quote.subtotal_minor)}", size: 16, align: :right
    if @quote.deposit_minor.to_i.positive?
      pdf.move_down 2
      pdf.fill_color MUTED
      pdf.text "Deposit #{money(@quote.deposit_minor)} · " \
        "Balance #{money(@quote.balance_due_minor)}" \
        "#{@quote.balance_due_on ? " due #{@quote.balance_due_on.strftime('%-d %B %Y')}" : ""}",
        size: 10, align: :right
      pdf.fill_color INK
    end
  end

  def notes_block(pdf)
    if @quote.included.present?
      pdf.text "What is included", size: 11, style: :bold
      pdf.move_down 2
      pdf.text @quote.included.to_s, size: 10, leading: 3
      pdf.move_down 8
    end
    if @quote.notes.present?
      pdf.text "A note from Sam", size: 11, style: :bold
      pdf.move_down 2
      pdf.text @quote.notes.to_s, size: 10, leading: 3
    end
  end

  def accept_block(pdf)
    pdf.fill_color OCHRE
    pdf.text "Accept this quote", size: 12, style: :bold
    pdf.fill_color MUTED
    pdf.text "Tap the link to accept - no account needed. " \
      "Questions? Just reply to info@sherpaholidays.com.", size: 9
    pdf.move_down 2
    pdf.fill_color OCHRE
    pdf.text @accept_url, size: 9
    pdf.fill_color INK
  end

  def footer(pdf)
    pdf.fill_color MUTED
    pdf.text "Sherpa Holidays · info@sherpaholidays.com · " \
      "Bookings, invoices, and travel documents are handled in PerfectBook.",
      size: 8, align: :center
    pdf.fill_color INK
  end

  def money(minor)
    "$#{format('%.2f', minor.to_i / 100.0).gsub(/(\d)(?=(\d{3})+\.)/, '\\1,')}"
  end
end
