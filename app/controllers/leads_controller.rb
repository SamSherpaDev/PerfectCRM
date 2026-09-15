class LeadsController < ApplicationController
  include RecordHistory

  before_action :set_lead, only: %i[show edit update convert refresh_bookings]
  before_action :block_converted_edit, only: %i[edit update]

  TABS = %w[new chatting quoted nudged lost converted].freeze

  def index
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "new"
    @query = params[:q].to_s.strip
    @sort = %w[activity name newest fit].include?(params[:sort]) ? params[:sort] : "activity"

    @counts = {
      "new" => Lead.by_status("new").count,
      "chatting" => Lead.by_status("chatting").count,
      "quoted" => Lead.by_status("quoted").count,
      "nudged" => Lead.by_status("nudged").count,
      "lost" => Lead.lost.count,
      "converted" => Lead.converted.count
    }

    base = if @tab == "converted"
      Lead.converted
    elsif @tab == "lost"
      Lead.lost
    else
      Lead.by_status(@tab)
    end
    scope = @query.present? ? base.search(@query) : base
    @leads = sort_leads(scope).includes(:tags, :people, :referred_by_organization, :converted_client)
    @automations = automation_rows
  end

  def show
    @matching_client = @lead.matching_client unless @lead.converted?
    if params[:nudge] == "1"
      template = Template.active.find_by(id: params[:template])
      if template
        context = {
          first_name: @lead.name.split.first, full_name: @lead.name,
          trip: @lead.trip_interest, advisor_name: @lead.referred_by_organization&.name,
          my_name: current_user.name, signature: current_user.name
        }
        @suggested_message = {
          subject: TemplateRenderer.render(template.subject, context),
          body: TemplateRenderer.render(template.body, context)
        }
      end
    end
    @note = Note.new
    load_record_history(@lead)
    @conversations = Conversation.where(linkable: @lead).ordered
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
    @lead.people.build
  end

  def update
    attrs = lead_params.to_h
    target_status = attrs.delete("status")
    if target_status.present? && !Lead::STATUSES.include?(target_status)
      @lead.errors.add(:status, "is not a lead stage")
      raise ActiveRecord::RecordInvalid, @lead
    end
    if target_status.present? && target_status != @lead.status
      Leads::Transition.call(@lead, to: target_status, actor: :captain,
        lost_reason: attrs.delete("lost_reason"), lost_note: attrs.delete("lost_note"),
        attributes: attrs)
    else
      @lead.update!(attrs)
    end
    redirect_to @lead, notice: "Lead saved."
  rescue ActiveRecord::RecordInvalid
    @lead.people.build unless @lead.people.any?(&:new_record?)
    render :edit, status: :unprocessable_entity
  end

  def convert
    if @lead.converted?
      return redirect_to @lead, alert: "Already converted."
    end
    client = Leads::Transition.call(@lead, to: "won",
      expected_client_id: params[:expected_client_id].presence || "new").converted_client
    redirect_to client, notice: "Lead converted. Their timeline moved with them."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @lead, alert: e.record.errors.full_messages.to_sentence.presence || "Could not convert."
  end

  def refresh_bookings
    if @lead.perfectbook_contact_id.present?
      PerfectBook::SyncBookingsJob.perform_later(perfectbook_contact_id: @lead.perfectbook_contact_id)
      redirect_to @lead, notice: "Refreshing bookings from PerfectBook."
    else
      redirect_to @lead, alert: "Link a PerfectBook contact first."
    end
  end

  private

  def set_lead
    @lead = Lead.includes(:tags, :people, :referred_by_organization, :converted_client).find(params[:id])
  end

  def block_converted_edit
    if @lead.converted?
      redirect_to @lead, alert: "Converted leads stay read-only."
    end
  end

  # One row per configured integration for the Automations strip:
  # the website form, Panda AI verdicts, and the n8n webhooks.
  def automation_rows
    settings = Setting.current
    last_intake = Lead.where.not(external_ref: nil).order(received_at: :desc, created_at: :desc).first
    last_verdict = ActivityEvent.where(kind: "automation").newest_first.first
    last_delivery = LeadWebhookDelivery.newest_first.first
    webhook_detail = if settings.webhooks_enabled?
      last_delivery ? "#{last_delivery.event} #{last_delivery.status} #{helpers.time_ago_in_words(last_delivery.created_at)} ago" : "Configured, nothing sent yet"
    else
      "Disabled: add a webhook URL in Settings"
    end
    [
      {
        name: "Website form", icon: :globe,
        detail: last_intake ? "Last inquiry #{helpers.time_ago_in_words(last_intake.received_at || last_intake.created_at)} ago" : "No inquiries yet",
        badge: last_intake ? [ "Automated", :info ] : [ "Manual", :neutral ]
      },
      {
        name: "Panda AI", icon: :robot,
        detail: last_verdict ? last_verdict.summary.truncate(80) : "Scores new leads",
        badge: last_verdict ? [ "Automated", :info ] : [ "Manual", :neutral ]
      },
      {
        name: "n8n webhooks", icon: :bolt,
        detail: webhook_detail,
        badge: settings.webhooks_enabled? ? [ "Automated", :info ] : [ "Manual", :neutral ]
      }
    ]
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
    params.permit(:name, :email, :source, :campaign_name, :external_ref).to_h
  end

  def lead_params
    params.require(:lead).permit(
      :name, :email, :phone, :country, :state, :kind, :source, :campaign_name,
      :external_ref, :fit_score, :fit_band, :fit_reason, :status,
      :referred_by_organization_id, :perfectbook_contact_id, :tag_list,
      :trip_interest, :expected_value_dollars, :lost_reason, :lost_note,
      people_attributes: %i[id name email phone role _destroy]
    )
  end
end
