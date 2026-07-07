class Event::RelayJob < ApplicationJob
  queue_as :default

  # Solid Queue's native semaphore blocks an overlapping tick: the recurring
  # schedule guarantees one enqueue per minute, not that tick N finished before
  # N+1 starts. A second relay enqueued while one holds the semaphore is blocked
  # (not dropped) and released when the holder finishes.
  #
  # But read the guarantee precisely: the semaphore is a fixed-TTL LEASE, not a
  # lock held for the job's lifetime. expires_at is stamped once at acquisition
  # (concurrency_duration, 3 min by default) and never refreshed; the
  # dispatcher's maintenance loop reaps any expired lease regardless of whether
  # the holder is still running. So a tick that runs LONGER than the lease loses
  # its exclusivity mid-run and the next tick runs concurrently — exactly the
  # double-dispatch this guard is supposed to prevent. The defense is not the
  # semaphore alone: it is keeping every tick comfortably shorter than the lease
  # by bounding both sweeps (Event::RELAY_BATCH). A backlog drains over several
  # short ticks instead of one long one. On Postgres, pg_try_advisory_xact_lock
  # would be the real lock; the lease is the SQLite-era approximation.
  #
  # Inert under the :test adapter; the semantics live in solid_queue's Semaphore.
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
