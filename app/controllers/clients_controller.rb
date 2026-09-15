class ClientsController < ApplicationController
  before_action :set_client, only: %i[show edit update archive unarchive]

  def index
    @tab = %w[clients organizations archived].include?(params[:tab]) ? params[:tab] : "clients"
    @query = params[:q].to_s.strip
    @sort = %w[activity name newest].include?(params[:sort]) ? params[:sort] : "activity"

    @clients_count = Client.active.count
    @organizations_count = Organization.count
    @archived_count = Client.archived.count

    if @tab == "organizations"
      scope = Organization.search(@query)
      @organizations = sort_organizations(scope)
    else
      base = @tab == "archived" ? Client.archived : Client.active
      scope = @query.present? ? base.search(@query) : base
      @clients = sort_clients(scope).includes(:tags, :people, :referred_by_organization)
    end
  end

  def show
    @note = Note.new
    @events = @client.activity_events.newest_first.limit(100)
    @notes = @client.notes.newest_first.limit(50).includes(:author)
    @origin_lead = Lead.find_by(converted_client_id: @client.id)
  end

  def new
    @client = Client.new(client_prefill)
    2.times { @client.people.build } if @client.people.empty?
  end

  def create
    @client = Client.new(client_params)
    if @client.save
      redirect_to @client, notice: "Client saved."
    else
      (@client.people.build while @client.people.size < 2)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @client.people.build if @client.people.empty?
  end

  def update
    if @client.update(client_params)
      redirect_to @client, notice: "Client saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def archive
    @client.archive!
    redirect_to clients_path(tab: "archived"), notice: "Client archived."
  end

  def unarchive
    @client.unarchive!
    redirect_to @client, notice: "Client restored."
  end

  # Target of PerfectBook's "Open in PerfectCRM" links.
  def by_perfectbook
    raw = params[:perfectbook_contact_id].to_s.strip
    record_id = Integer(raw, exception: false)
    return render_not_found if record_id.nil? || record_id <= 0

    if (client = Client.find_by(perfectbook_contact_id: record_id))
      return redirect_to client_path(client)
    end
    if (organization = Organization.find_by(perfectbook_contact_id: record_id))
      return redirect_to organization_path(organization)
    end

    # TODO: when the sibling PerfectBook API client lands (PerfectBook::Client),
    # fetch the contact here and build the record in one tap instead of
    # prefilling the form. Until then, offer the create form with the id kept.
    @client = Client.new(perfectbook_contact_id: record_id)
    @client.people.build
    render :by_perfectbook, status: :not_found
  end

  private

  def set_client
    @client = Client.includes(:tags, :people, :referred_by_organization).find(params[:id])
  end

  def sort_clients(scope)
    case @sort
    when "name" then scope.by_name
    when "newest" then scope.order(created_at: :desc)
    else scope.ordered
    end
  end

  def sort_organizations(scope)
    case @sort
    when "name" then scope.order(:name)
    when "newest" then scope.order(created_at: :desc)
    else scope.ordered
    end.includes(:tags)
  end

  def client_prefill
    params.permit(:name, :email, :perfectbook_contact_id).to_h
  end

  def client_params
    params.require(:client).permit(
      :name, :email, :phone, :country, :state, :kind, :source,
      :referred_by_organization_id, :perfectbook_contact_id, :tag_list,
      people_attributes: %i[id name email phone role _destroy]
    )
  end

  def render_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
