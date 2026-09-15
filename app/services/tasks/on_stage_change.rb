# Hook the pipeline board calls when a lead or client changes stage.
#
# The pipeline task owns stages and calls
# `Tasks::OnStageChange.call(subject:, from:, to:)`. Each stage maps to an
# optional task template: when the stage names a template purpose, a
# follow-up task is proposed for the captain (never sent, never automatic
# mail). Stages absent from the map propose nothing.
#
# Example: `{ "quoted" => { purpose: :itinerary_follow_up, days: 3 } }`
# proposes an itinerary follow-up due in three days on entering "quoted".
module Tasks
  module OnStageChange
    STAGE_TASK_TEMPLATES = {}.freeze

    module_function

    def call(subject:, from:, to:)
      plan = STAGE_TASK_TEMPLATES[to.to_s]
      return nil if plan.nil?

      template = ::Template.active.for_purpose(plan.fetch(:purpose)).ordered.first
      subject.tasks.create!(
        title: "Follow up on #{to.to_s.humanize.downcase} (#{subject.name})",
        kind: "follow_up", due_on: Date.current + plan.fetch(:days, 3).days,
        created_by: "automation", template: template
      )
    end
  end
end
