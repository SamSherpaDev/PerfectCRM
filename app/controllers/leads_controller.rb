class LeadsController < ApplicationController
  include ReplyBox
  include RecordPage
  include ListReturnPath

  before_action :set_lead, only: %i[show edit update convert refresh_bookings archive unarchive mark_as_spam not_spam mark_potential unmark_potential mark_unsure unmark_unsure mark_not_interested unmark_not_interested]
  before_action :block_converted_edit, only: %i[edit update]
  before_action :block_archived_edit, only: %i[edit update]

  TABS = %w[new potential unsure quoted not_interested archived missing_source].freeze
  SORTS = %w[activity name newest fit].freeze
  # Stages without their own tab: chatting and nudged wait in New until
  # sorted, and lost rests with Archived. Converted leads live on as clients,
  # so the retired Converted tab opens New. Old links land on that home.
  RETIRED_TABS = { "chatting" => "new", "nudged" => "new", "lost" => "archived", "converted" => "new" }.freeze

  def index
    if (home = RETIRED_TABS[params[:tab]])
      return redirect_to leads_path(params.permit(:q, :sort).to_h.merge(tab: home))
    end
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "new"
    @query = params[:q].to_s.strip
    @sort = SORTS.include?(params[:sort]) ? params[:sort] : "activity"
    @lead_action_return_to = leads_path(tab: @tab, q: @query, sort: @sort)
    new_leads = Lead.in_new_tab
    quoted_leads = Lead.by_status("quoted").where(not_interested_marked_at: nil)
    set_aside = Lead.archived.or(Lead.lost.where(not_interested_marked_at: nil))

    @counts = {
      "new" => new_leads.count,
      "potential" => Lead.potential.count,
      "unsure" => Lead.unsure.count,
      "quoted" => quoted_leads.count,
      "not_interested" => Lead.not_interested.count,
      "archived" => set_aside.count
    }

    base = case @tab
    when "new" then new_leads
    when "potential" then Lead.potential
    when "unsure" then Lead.unsure
    when "quoted" then quoted_leads
    when "not_interested" then Lead.not_interested
    when "archived" then set_aside
    else Lead.by_status(@tab)
    end
    base = WeeklyReport::Monthly.new.eligible_leads.where(source_answer_state: "not_asked") if @tab == "missing_source"
    scope = @query.present? ? base.search(@query) : base
    @leads = sort_leads(scope).includes(:tags, :people, :referred_by_organization, :converted_client, :scheduled_calls)
  end

  def show
    @lead_action_return_to = safe_leads_return_path(params[:return_to]) || leads_path(tab: "new")
    @matching_client = @lead.matching_client unless @lead.converted?
    @note = Note.new
    load_reply_box(@lead)
    load_record_page(@lead)
  end

  def new
    @lead = Lead.new(lead_prefill)
    @lead.people.build if @lead.people.empty?
  end

  def create
    @lead = Lead.new(lead_params)
    if @lead.save
      redirect_to @lead, notice: "Lead saved."
    else
      @lead.people.build if @lead.people.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @lead_action_return_to = safe_leads_return_path(params[:return_to]) || leads_path(tab: "new")
    @lead.people.build
  end

  def update
    @lead_action_return_to = safe_leads_return_path(params[:return_to]) || leads_path(tab: "new")
    attrs = lead_params.to_h
    target_status = attrs.delete("status")
    if target_status.present? && !Lead::STATUSES.include?(target_status)
      @lead.errors.add(:status, "is not a lead stage")
      raise ActiveRecord::RecordInvalid, @lead
    end
    status_changed = target_status.present? && target_status != @lead.status
    if status_changed
      Leads::Transition.call(@lead, to: target_status, actor: :captain,
        lost_reason: attrs.delete("lost_reason"), lost_note: attrs.delete("lost_note"),
        attributes: attrs)
    else
      @lead.update!(attrs)
    end
    if status_changed
      redirect_to lead_action_return_to, notice: "Marked as #{target_status.humanize} - moved to #{lead_destination_tab}."
    else
      redirect_to record_path_keeping_list(@lead), notice: "Lead saved."
    end
  rescue ActiveRecord::RecordInvalid
    @lead.people.build unless @lead.people.any?(&:new_record?)
    render :edit, status: :unprocessable_entity
  end

  def convert
    if @lead.archived?
      return redirect_to record_path_keeping_list(@lead), alert: "Restore this lead before converting."
    end
    if @lead.converted?
      return redirect_to record_path_keeping_list(@lead), alert: "Already converted."
    end
    client = Leads::Transition.call(@lead, to: "won",
      expected_client_id: params[:expected_client_id].presence || "new").converted_client
    redirect_to client, notice: "Lead converted. Their timeline moved with them."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence.presence || "Could not convert."
  end

  def archive
    if @lead.converted?
      return redirect_to record_path_keeping_list(@lead), alert: "Converted leads stay read-only."
    end
    @lead.archive!
    redirect_to lead_action_return_to, notice: "Archived - moved to Archived. Choose Restore to bring this lead back."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence.presence || "Could not archive."
  end

  def unarchive
    @lead.unarchive!
    redirect_to lead_action_return_to, notice: "Restored - moved to #{lead_destination_tab}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence.presence || "Could not restore."
  end

  def mark_as_spam
    @lead.mark_as_spam!
    redirect_to lead_action_return_to, notice: "Marked as spam - moved to Archived. Choose Not spam to restore."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence.presence || "Could not mark as spam."
  end

  def not_spam
    @lead.mark_not_spam!
    redirect_to lead_action_return_to, notice: "Not spam - restored to #{lead_destination_tab}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence.presence || "Could not clear spam."
  end

  def mark_potential
    @lead.mark_potential!
    redirect_to lead_action_return_to, notice: "Marked as Potential - moved to Potential."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence
  end

  def unmark_potential
    @lead.unmark_potential!
    redirect_to lead_action_return_to, notice: "Removed from Potential - moved to #{lead_destination_tab}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence
  end

  def mark_unsure
    @lead.mark_unsure!
    redirect_to lead_action_return_to, notice: "Marked as Unsure - moved to Unsure."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence
  end

  def unmark_unsure
    @lead.unmark_unsure!
    redirect_to lead_action_return_to, notice: "Removed from Unsure - moved to #{lead_destination_tab}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence
  end

  def mark_not_interested
    @lead.mark_not_interested!
    redirect_to lead_action_return_to, notice: "Marked as not interested - moved to Not interested. Choose Interested again to restore."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence
  end

  def unmark_not_interested
    @lead.unmark_not_interested!
    redirect_to lead_action_return_to, notice: "Interested again - moved to #{lead_destination_tab}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to record_path_keeping_list(@lead), alert: e.record.errors.full_messages.to_sentence
  end

  def refresh_bookings
    if @lead.perfectbook_contact_id.present?
      PerfectBook::SyncBookingsJob.perform_later(perfectbook_contact_id: @lead.perfectbook_contact_id)
      redirect_to record_path_keeping_list(@lead), notice: "Refreshing bookings from PerfectBook."
    else
      redirect_to record_path_keeping_list(@lead), alert: "Link a PerfectBook contact first."
    end
  end

  private

  def set_lead
    @lead = Lead.includes(:tags, :people, :referred_by_organization, :converted_client, :scheduled_calls).find(params[:id])
  end

  def block_converted_edit
    if @lead.converted?
      redirect_to record_path_keeping_list(@lead), alert: "Converted leads stay read-only."
    end
  end

  def block_archived_edit
    if @lead.archived?
      redirect_to record_path_keeping_list(@lead), alert: "Archived leads stay read-only until restored."
    end
  end

  def sort_leads(scope)
    case @sort
    when "name" then scope.reorder(:name)
    when "newest" then scope.reorder(created_at: :desc)
    when "fit" then scope.reorder(Arel.sql("fit_score DESC NULLS LAST, COALESCE(last_activity_at, updated_at) DESC"))
    else scope.ordered
    end
  end

  def lead_prefill
    params.permit(:name, :email, :source, :campaign_name, :external_ref, :existing_client_id, :capture_channel).to_h
  end

  def lead_params
    params.require(:lead).permit(
      :name, :email, :phone, :country, :state, :kind, :source, :campaign_name,
      :external_ref, :fit_score, :fit_band, :fit_reason, :owner_fit_at_inquiry, :status,
      :referred_by_organization_id, :perfectbook_contact_id, :tag_list, :ai_opt_out,
      :trip_interest, :expected_value_dollars, :lost_reason, :lost_note,
      :source_choice, :reported_source_detail, :source_correction_reason, :capture_channel, :is_test,
      :existing_client_id, :referred_by_client_id, :referred_by_person_id,
      people_attributes: %i[id name email phone role _destroy]
    )
  end

  def lead_action_return_to
    safe_leads_return_path(params[:return_to]) || leads_path(tab: "new")
  end

  def lead_destination_tab
    return "Not interested" if @lead.not_interested?
    return "Potential" if @lead.potential?
    return "Unsure" if @lead.unsure?
    return "Quoted" if @lead.status == "quoted"
    return "Archived" if @lead.archived? || @lead.status == "lost"

    "New"
  end
end
