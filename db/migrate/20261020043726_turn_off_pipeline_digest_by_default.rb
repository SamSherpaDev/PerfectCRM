# The Monday pipeline note's Settings toggle is hidden, so it sends only
# when enabled explicitly (README.md, "Pipeline").
class TurnOffPipelineDigestByDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :settings, :pipeline_digest, from: true, to: false
    execute "UPDATE settings SET pipeline_digest = 0"
  end

  def down
    change_column_default :settings, :pipeline_digest, from: false, to: true
  end
end
