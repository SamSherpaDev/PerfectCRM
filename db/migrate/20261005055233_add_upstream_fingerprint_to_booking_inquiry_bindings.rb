class AddUpstreamFingerprintToBookingInquiryBindings < ActiveRecord::Migration[8.1]
  def change
    add_column :booking_inquiry_bindings, :upstream_fingerprint, :string
  end
end
