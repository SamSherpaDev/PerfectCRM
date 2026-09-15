class TasksController < ApplicationController
  before_action :set_task, only: %i[complete snooze]

  # From the client task card, or one-tap "Create review ask" on Today.
  def create
    subject = find_subject
    return render_not_found if subject.nil?

    @task = subject.tasks.build(task_params.merge(created_by: "captain"))
    if @task.save
      redirect_back fallback_location: subject, notice: "Follow-up saved."
    else
      redirect_back fallback_location: subject, alert: @task.errors.full_messages.to_sentence
    end
  end

  def create_review_ask
    booking = PerfectBook::Booking.find(params[:booking_id])
    subject = Tasks::Automatic.subject_for(booking)
    return render_not_found if subject.nil?

    template = ::Template.active.for_purpose(:review_ask).ordered.first
    subject.tasks.create_with(
      title: "Ask #{subject.name} for a review (#{booking.trip_name})", kind: "review_ask",
      due_on: Date.current, created_by: "captain", template: template,
      notes: booking.ref.present? ? "Booking #{booking.ref}." : nil
    ).find_or_create_by!(idempotency_key: "review-ask:#{booking.perfectbook_id}")
    redirect_back fallback_location: root_path, notice: "Review ask saved."
  end

  def complete
    @task.complete!
    redirect_back fallback_location: root_path, notice: "Done. Nice."
  end

  def snooze
    if @task.snooze!(params[:preset].to_s, date: parse_snooze_date)
      redirect_back fallback_location: root_path, notice: "Snoozed."
    else
      redirect_back fallback_location: root_path, alert: "Pick a date to snooze until."
    end
  end

  private

  def set_task
    @task = Task.find(params[:id])
  end

  def find_subject
    case params[:subject_type].to_s
    when "Client" then Client.find_by(id: params[:subject_id])
    when "Lead" then Lead.find_by(id: params[:subject_id])
    when "Organization" then Organization.find_by(id: params[:subject_id])
    end
  end

  def task_params
    params.require(:task).permit(:title, :kind, :due_on, :due_at, :template_id, :notes)
  end

  def parse_snooze_date
    raw = params[:snoozed_until].to_s.strip
    return nil if raw.blank?

    Date.parse(raw)
  rescue Date::Error, ArgumentError
    nil
  end

  def render_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
