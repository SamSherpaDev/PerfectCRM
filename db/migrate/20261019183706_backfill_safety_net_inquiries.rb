class BackfillSafetyNetInquiries < ActiveRecord::Migration[8.1]
  def up
    Leads::UnlinkedInquiries.new.resolve! if defined?(Leads::UnlinkedInquiries)
  end

  def down
  end
end
