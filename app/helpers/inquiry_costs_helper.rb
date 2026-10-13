module InquiryCostsHelper
  def inquiry_cost_money(amounts)
    return "Unknown" if amounts.nil?

    safe_join(amounts.sort.map { |currency, amount| currency == "USD" ? "#{money(amount)} USD" : money_in(amount, currency) }, tag.br)
  end

  def inquiry_cost_count(row)
    return number_with_delimiter(row.inquiries) if row.unassigned.zero?

    safe_join([ "Unknown", tag.span("#{row.inquiries} matched; #{row.unassigned} unassigned", class: "hint block") ])
  end
end
