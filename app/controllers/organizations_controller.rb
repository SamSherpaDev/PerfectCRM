class OrganizationsController < ApplicationController
  include RecordHistory

  before_action :set_organization, only: %i[show edit update destroy]

  def show
    @note = Note.new
    load_record_history(@organization)
    @referred_clients = @organization.referred_clients.active.ordered.limit(20).includes(:tags)
  end

  def new
    @organization = Organization.new(organization_prefill)
  end

  def create
    @organization = Organization.new(organization_params)
    if @organization.save
      redirect_to @organization, notice: "Organization saved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @organization.update(organization_params)
      redirect_to @organization, notice: "Organization saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @organization.destroy!
    redirect_to clients_path(tab: "organizations"), notice: "Organization removed.", status: :see_other
  end

  private

  def set_organization
    @organization = Organization.includes(:tags).find(params[:id])
  end

  def organization_prefill
    params.permit(:name, :email, :perfectbook_contact_id).to_h
  end

  def organization_params
    params.require(:organization).permit(
      :name, :kind, :email, :phone, :country, :website, :perfectbook_contact_id, :tag_list
    )
  end
end
