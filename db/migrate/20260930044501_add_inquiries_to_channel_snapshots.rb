class AddInquiriesToChannelSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :channel_snapshots, :inquiries, :integer
  end
end
