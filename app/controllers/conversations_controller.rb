class ConversationsController < ApplicationController
  before_action :set_conversation, only: %i[show link ignore make_client make_lead make_organization]

  def show
    redirect_to inbox_thread_path(@conversation)
  end

  # Link triage thread to an existing client, lead, or organization.
  def link
    target = find_target
    return redirect_to inbox_thread_path(@conversation), alert: "Pick a record to link." if target.nil?

    @conversation.update!(linkable: target, ignored: false)
    EmailIdentity.remember!(sender_email, linkable: target)
    ActivityEvent.create!(subject: target, kind: "email",
      summary: "Email linked: #{@conversation.display_subject}",
      occurred_at: Time.current, metadata: { "conversation_id" => @conversation.id, "via" => "triage" })
    redirect_to inbox_thread_path(@conversation), notice: "Linked to #{target.name}."
  end

  def ignore
    @conversation.update!(ignored: true)
    EmailIdentity.remember!(sender_email, ignored: true) if sender_email.present?
    redirect_to inbox_path(tab: "triage"), notice: "Sender ignored. Future mail skips triage."
  end

  def make_client
    sender = sender_email
    return redirect_to inbox_thread_path(@conversation), alert: "No sender to create from." if sender.blank?

    client = Client.find_by(email: sender) || Client.create!(name: display_name_for(sender), email: sender, source: "email")
    @conversation.update!(linkable: client, ignored: false)
    EmailIdentity.remember!(sender, linkable: client)
    redirect_to client_path(client), notice: "Client created and thread linked."
  end

  def make_lead
    sender = sender_email
    return redirect_to inbox_thread_path(@conversation), alert: "No sender to create from." if sender.blank?

    lead = Lead.find_by(email: sender) || Lead.create!(name: display_name_for(sender), email: sender, source: "email")
    @conversation.update!(linkable: lead, ignored: false)
    EmailIdentity.remember!(sender, linkable: lead)
    redirect_to lead_path(lead), notice: "Lead created and thread linked."
  end

  def make_organization
    sender = sender_email
    return redirect_to inbox_thread_path(@conversation), alert: "No sender to create from." if sender.blank?

    organization = Organization.find_by(email: sender) || Organization.create!(name: display_name_for(sender), email: sender, kind: "other")
    @conversation.update!(linkable: organization, ignored: false)
    EmailIdentity.remember!(sender, linkable: organization)
    redirect_to organization_path(organization), notice: "Organization created and thread linked."
  end

  private

  def set_conversation
    @conversation = Conversation.find(params[:id])
  end

  def find_target
    type = params[:linkable_type].to_s
    id = params[:linkable_id].to_s
    return nil if type.blank? || id.blank?

    case type
    when "Client" then Client.find_by(id: id)
    when "Lead" then Lead.find_by(id: id)
    when "Organization" then Organization.find_by(id: id)
    end
  end

  def sender_email
    first_in = @conversation.messages.inbound.order(sent_at: :desc).first
    raw = first_in&.from_address.presence || @conversation.other_participants.reject { |value| Mail.mailbox_aliases.include?(value) }.first
    raw.to_s.strip.downcase.presence
  end

  def display_name_for(email)
    email.split("@").first.to_s.split(/[._\-+]/).map(&:capitalize).join(" ").presence || email
  end
end
