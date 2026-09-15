module ApplicationHelper
  # Status vocabulary shared across the app; unknown values fall back to neutral.
  STATUS_TONES = {
    "active" => :success, "paid" => :success, "posted" => :success, "settled" => :success,
    "closed" => :neutral, "done" => :success, "completed" => :success, "released" => :success,
    "confirmed" => :info, "departed" => :info, "upcoming" => :info, "open" => :brand,
    "sent" => :info, "partially_paid" => :warning,
    "enquiry" => :neutral, "quoted" => :brand, "agreement_sent" => :info,
    "deposit_received" => :info, "operator_confirmed" => :info,
    "balance_received" => :success, "travelling" => :brand,
    "pending" => :warning, "planned" => :neutral, "skipped" => :neutral, "inactive" => :neutral,
    "cancelled" => :danger, "refunded" => :warning, "voided" => :danger, "overdue" => :danger,
    "soft-deleted" => :danger,
    "connected" => :success, "pulling" => :info, "error" => :danger, "disconnected" => :neutral,
    "new" => :info, "chatting" => :neutral, "nudged" => :warning, "lost" => :neutral,
    "won" => :success, "post_trip" => :info, "stage_change" => :info,
    "draft" => :neutral, "viewed" => :info, "accepted" => :success,
    "declined" => :neutral, "expired" => :warning,
