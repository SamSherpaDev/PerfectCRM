namespace :terms do
  desc "Read-only persisted-template rollout inventory (no message or customer text)"
  task template_inventory: :environment do
    rows = Template.order(:id).map do |template|
      known = TemplatePolicyRefresh::PATCHES.keys.count { |clause| template.body.to_s.include?(clause) }
      {
        id: template.id, active: !template.archived?,
        known_stale_clauses: known,
        body_sha256: Digest::SHA256.hexdigest(template.body.to_s),
        review_required: known.zero? && template.body.to_s.match?(/acclimatiz|seats.*(?:hold|confirm)|Kathmandu|store.*secur|adjust anything/i)
      }
    end
    puts JSON.pretty_generate(rows)
  end
end
