# Weekly ad spend typed in on Settings, feeding cost per inquiry in the
# Monday ads report. Saving the same week, channel, and campaign again
# replaces the amount.
class AdSpendsController < ApplicationController
  def create
    attrs = params.require(:ad_spend).permit(:week_start, :source, :campaign_name, :amount_dollars)
    week = Date.iso8601(attrs[:week_start].to_s)
    entry = AdSpend.record!(week_start: week, source: attrs[:source],
      campaign_name: attrs[:campaign_name], amount_dollars: attrs[:amount_dollars])
    redirect_to back_to_card, notice: "Saved #{helpers.report_money(entry.amount_minor)} for #{entry_label(entry)}.", status: :see_other
  rescue Date::Error
    redirect_to back_to_card, alert: "Choose the week the money was spent.", status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    redirect_to back_to_card, alert: e.record.errors.full_messages.to_sentence, status: :see_other
  end

  def destroy
    entry = AdSpend.find(params[:id])
    entry.destroy!
    redirect_to back_to_card, notice: "Removed spend for #{entry_label(entry)}.", status: :see_other
  end

  private

  def back_to_card
    edit_settings_path(anchor: "weekly-report-heading")
  end

  def entry_label(entry)
    row = WeeklyReport::Summary::Row.new(source: entry.source, campaign: entry.campaign_name.presence)
    "#{row.label}, week of #{WeeklyReport::Summary.week_label(entry.week_start)}"
  end
end
