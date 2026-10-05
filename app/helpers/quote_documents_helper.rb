# Small, escaped presentation of the released Markdown documents. Tables
# become one-column facts so full legal wording stays readable at 390px.
# Downloads and acceptance hashes always retain the original document bytes.
module QuoteDocumentsHelper
  def booking_document_html(text)
    blocks = text.to_s.split(/\n\s*\n/).map do |block|
      lines = block.lines.map(&:strip)
      if lines.first.start_with?("|")
        rows = lines.drop(2).map do |line|
          cells = line.sub(/\A\|/, "").sub(/\|\z/, "").split("|", 2).map(&:strip)
          tag.div(safe_join([ tag.dt(cells.first), tag.dd(document_inline(cells.last.to_s)) ]))
        end
        tag.dl(safe_join(rows), class: "facts facts-col mt-3")
      elsif lines.first.start_with?("#")
        tag.h3(lines.first.sub(/\A\#+\s*/, ""), class: "font-display text-lg mt-4")
      else
        tag.p(document_inline(block), class: "mt-3 text-sm break-words whitespace-pre-line")
      end
    end
    safe_join(blocks)
  end

  private

  def document_inline(text)
    safe_join(text.split(/(\*\*.*?\*\*)/m).map do |part|
      part.start_with?("**") && part.end_with?("**") ? tag.strong(part[2...-2]) : part
    end)
  end
end
