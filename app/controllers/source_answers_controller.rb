class SourceAnswersController < ApplicationController
  def create
    record = source_record
    owner = record.is_a?(Person) ? record.owner : record
    return redirect_to owner, alert: "Restore this record before editing." if owner.archived?
    return redirect_to owner, alert: "Confirm source on the client." if owner.is_a?(Lead) && owner.converted?

    SourceAnswers.record!(record, choice: params[:source_choice], detail: params[:detail],
      method: "call", reason: params[:correction_reason], evidence: params[:evidence_reference],
      referrals: params.permit(:referred_by_client_id, :referred_by_person_id).to_h)
    redirect_to(record.is_a?(Person) ? record.owner : record, notice: "Source saved.")
  rescue ActiveRecord::RecordInvalid => error
    redirect_to(record.is_a?(Person) ? record.owner : record, alert: error.record.errors.full_messages.to_sentence)
  end

  private

  def source_record
    case params[:record_type]
    when "Lead" then Lead.find(params[:record_id])
    when "Client" then Client.find(params[:record_id])
    when "Person" then Person.find(params[:record_id])
    else raise ActiveRecord::RecordNotFound
    end
  end
end
