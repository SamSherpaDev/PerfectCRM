# Proposes follow-up tasks from the mirrored PerfectBook bookings.
#
# Three rules, each firing once per booking (idempotency_key):
# - Review ask, three days after the departure ends.
# - Repeat-trip nudge, ten months after return.
# - Deposit nudge, when a mirrored invoice reads sent (or overdue) with a
#   balance due on a booking first seen at least five days ago that has not
#   started yet.
#
# Every rule only creates a task the captain acts on; nothing ever sends
# mail. Bookings with no local client, lead, or organization are skipped.
module Tasks
  module Automatic
    REVIEW_DELAY = 3.days
    REPEAT_DELAY = 10.months
    DEPOSIT_UNPAID_FOR = 5.days

    module_function

    # Runs every rule for today's date. Returns the tasks created.
    def run!(today: Date.current)
      created = []
      PerfectBook::Booking.find_each do |booking|
        subject = subject_for(booking)
        next if subject.nil?

        created << try_review_ask!(booking, subject, today)
        created << try_repeat_nudge!(booking, subject, today)
        created << try_deposit_nudge!(booking, subject, today)
      end
      created.compact
    end

    def try_review_ask!(booking, subject, today)
      return nil if booking.end_date.blank? || booking.end_date + REVIEW_DELAY > today

      create_once!(
        key: "review-ask:#{booking.perfectbook_id}", subject: subject,
        title: "Ask #{subject.name} for a review (#{booking.trip_name})",
        kind: "review_ask", due_on: booking.end_date + REVIEW_DELAY, template: template_for(:review_ask),
        notes: booking.ref.present? ? "Booking #{booking.ref}." : nil
      )
    end

    def try_repeat_nudge!(booking, subject, today)
      return nil if booking.end_date.blank?
      return nil if booking.end_date + REPEAT_DELAY > today

      create_once!(
        key: "repeat-nudge:#{booking.perfectbook_id}", subject: subject,
        title: "Invite #{subject.name} back to the mountains (#{booking.trip_name})",
        kind: "follow_up", due_on: booking.end_date + REPEAT_DELAY, template: template_for(:repeat_nudge),
        notes: booking.ref.present? ? "Last travelled #{booking.end_date} on #{booking.ref}." : nil
      )
    end

    def try_deposit_nudge!(booking, subject, today)
      return nil unless %w[sent overdue].include?(booking.invoice_badge.to_s)
      return nil if booking.balance_due_minor.to_i <= 0
      return nil if booking.start_date.present? && booking.start_date <= today
      return nil if booking.created_at.blank? || booking.created_at > DEPOSIT_UNPAID_FOR.ago

      create_once!(
        key: "deposit-nudge:#{booking.perfectbook_id}:#{booking.invoice_number}", subject: subject,
        title: "Nudge #{subject.name} about the deposit (#{booking.invoice_number})",
        kind: "payment_nudge", due_on: today, template: template_for(:deposit_nudge),
        notes: "Invoice #{booking.invoice_number} reads sent with a balance due."
      )
    end

    def subject_for(booking)
      Client.find_by(perfectbook_contact_id: booking.perfectbook_contact_id) ||
        Organization.find_by(perfectbook_contact_id: booking.perfectbook_contact_id) ||
        Lead.find_by(perfectbook_contact_id: booking.perfectbook_contact_id)
    end

    def create_once!(key:, **attrs)
      Task.create_with(attrs.merge(created_by: "automation")).find_or_create_by!(idempotency_key: key)
    rescue ActiveRecord::RecordNotUnique
      Task.find_by!(idempotency_key: key)
    end

    def template_for(purpose)
      ::Template.active.for_purpose(purpose).ordered.first
    end
  end
end
