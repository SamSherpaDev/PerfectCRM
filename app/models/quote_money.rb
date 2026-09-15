module QuoteMoney
  def self.parse(value)
    return 0 if value.empty?
    return nil unless /\A[0-9]+(?:\.[0-9]{1,2})?\z/.match?(value)

    (BigDecimal(value) * 100).to_i
  end
end
