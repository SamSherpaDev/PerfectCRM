module QuotesHelper
  def quote_send_confirm(quote)
    owner = quote.owner
    "This lead is marked not interested - do not contact. Send this quote anyway?" if owner.is_a?(Lead) && owner.not_interested?
  end
end
