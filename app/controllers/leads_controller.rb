class LeadsController < ApplicationController
  include RecordHistory

  before_action :set_lead, only: %i[show edit update convert]
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
  end

  def show
    @matching_client = @lead.matching_client unless @lead.converted?
    @note = Note.new
    load_record_history(@lead)
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
    if @lead.update(lead_params)
      redirect_to @lead, notice: "Lead saved."
    else
      @lead.people.build unless @lead.people.any?(&:new_record?)
      render :edit, status: :unprocessable_entity
    end
  end

  def convert
    if @lead.converted?
      return redirect_to @lead, alert: "Already converted."
    end
    client = @lead.convert_to_client!(expected_client_id: params[:expected_client_id])
    redirect_to client, notice: "Lead converted. Their timeline moved with them."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @lead, alert: e.record.errors.full_messages.to_sentence.presence || "Could not convert."
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
      people_attributes: %i[id name email phone role _destroy]
    )
  end
end
