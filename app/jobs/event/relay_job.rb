class Event::RelayJob < ApplicationJob
  queue_as :default

  # Solid Queue's native semaphore serializes overlapping ticks: the recurring
  # schedule guarantees one enqueue per minute, not that tick N finished before
  # N+1 starts. A second relay enqueued while one holds the semaphore is
  # blocked (not dropped) and released when the holder finishes or the
  # concurrency duration (3 minutes by default) expires. Inert under the
  # :test adapter; the semantics live in solid_queue's Semaphore.
  limits_concurrency key: "event_relay", to: 1

  # Two tiers, both required. Tier 1 recovers a lost fanout (crash between
  # commit and enqueue): a crash-gapped event has zero delivery rows, so a
  # delivery-only scan would never see it. Tier 2 recovers a lost effect
  # (job crashed, exhausted, or parked after enqueue): without it,
  # dispatched_at says everything worked while a subscriber quietly never ran.
  #
  # The notify line is the relay's liveness signal: a monitor alerts on its
  # absence, because Solid Queue shows jobs that failed, not jobs that never ran.
  def perform
    stranded = Event.relay_stranded
    redelivered, failed = Event::Delivery.redeliver_stale

    Rails.event.notify("event_relay.swept", stranded:, redelivered:, failed:)
  end
end
