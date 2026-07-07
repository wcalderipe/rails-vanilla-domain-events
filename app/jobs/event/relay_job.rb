class Event::RelayJob < ApplicationJob
  queue_as :default

  # Two tiers, both required. Tier 1 recovers a lost fanout (crash between
  # commit and enqueue): a crash-gapped event has zero delivery rows, so a
  # delivery-only scan would never see it. Tier 2 recovers a lost effect
  # (job crashed, exhausted, or parked after enqueue): without it,
  # dispatched_at says everything worked while a subscriber quietly never ran.
  def perform
    Event.relay_stranded
    Event::Delivery.redeliver_stale
  end
end
