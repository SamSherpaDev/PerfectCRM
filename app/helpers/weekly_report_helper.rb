# Formatting for the Monday ads report, shared by the email and its
# preview on Settings. Whole dollars: the report is for decisions.
module WeeklyReportHelper
  def report_money(minor)
    return "-" if minor.nil?

    "$#{number_with_delimiter((minor / 100.0).round)}"
  end

  def report_count(count, singular, plural = singular.pluralize)
    "#{count} #{count == 1 ? singular : plural}"
  end

  def report_hours(hours)
    return "no replies yet" if hours.nil?
    return "#{(hours * 60).round} min" if hours < 1

    "#{hours.round(hours < 10 ? 1 : 0).to_s.delete_suffix('.0')} h"
  end

  # "Google EBC: $126 spend | 3 inq | 1 qual | 0 quoted | 0 booked | $42/inq | $126/qual"
  def report_row_line(row, label: row.label, costs: true)
    parts = []
    parts << "#{report_money(row.spend_minor)} spend" if costs
    parts << "#{row.inquiries} inq" << "#{row.qualified} qual" << "#{row.quoted} quoted" << "#{row.booked} booked"
    parts << "#{report_money(row.booked_value_minor)} booked value" if row.booked.positive?
    if costs
      parts << "#{report_money(row.cost_per_inquiry)}/inq"
      parts << "#{report_money(row.cost_per_qualified)}/qual"
      parts << "#{report_money(row.cost_per_booking)}/booking" if row.booked.positive?
    end
    "#{label}: #{parts.join(' | ')}"
  end

  def report_goal_line(summary)
    goal = summary.travelers_goal
    year = summary.week_end.year
    return if goal.nil?

    head = "Goal: #{report_count(goal, 'traveler')} by Dec 31, #{year}. So far #{summary.year_travelers}."
    pace = summary.goal_pace
    return "#{head} Goal reached." if summary.year_travelers >= goal

    "#{head} Need #{pace.to_s.delete_suffix('.0')} a week for #{report_count(summary.weeks_left_in_year, 'week')}."
  end

  def report_period_line(period)
    "#{period.label} to date: #{report_count(period.inquiries, 'inquiry', 'inquiries')}, " \
      "#{period.qualified} qualified, #{report_count(period.booked, 'booking')}, " \
      "#{report_count(period.travelers, 'traveler')}"
  end

  def report_milestone_line(summary)
    milestone = summary.milestone
    return unless milestone

    "Since Oct 1: #{milestone[:travelers]} new travelers booked (target #{milestone[:target]} by #{milestone[:deadline].strftime('%b %-d')})."
  end

  def report_flags_line(summary)
    "Flags: #{summary.flags.presence&.join(' | ') || 'None'}."
  end

  def report_missing_spend_line(summary)
    return "Spend not entered for this week yet." if summary.missing_spend_labels.empty?

    "Spend not entered for: #{summary.missing_spend_labels.join(', ')}."
  end

  def report_speed_line(summary)
    line = "Speed: median first reply #{report_hours(summary.median_first_reply_hours)}"
    waiting = summary.waiting.size
    "#{line} | #{report_count(waiting, 'inquiry', 'inquiries')} waiting over 24 h"
  end

  def report_lead_name(lead)
    [ lead.reference.presence, lead.name ].compact.join(" ")
  end

  def report_placements(summary)
    summary.placements.map { |name, count| "#{name.tr('_', ' ')} #{count}" }.join(", ")
  end

  def report_agreement_line(summary)
    agreement = summary.ai_agreement
    return "AI fit vs your call: nothing to compare yet (last 4 weeks)." if agreement[:total].zero?

    percent = (agreement[:agreed] * 100.0 / agreement[:total]).round
    "AI fit vs your call: #{agreement[:agreed]} of #{agreement[:total]} agree (#{percent}%, last 4 weeks, target 80%+)."
  end
end
