class Event::RelayJob < ApplicationJob
  queue_as :default

  # Solid Queue's semaphore blocks an overlapping tick, it doesn't drop it. The
  # recurring schedule guarantees one enqueue per minute, not that tick N
  # finishes before N+1 starts. A second relay enqueued while one holds the
  # semaphore waits and runs once the holder finishes.
  #
  # But the guarantee is limited: the semaphore is a fixed-TTL lease, not a
  # lock held for the job's whole lifetime. expires_at is stamped once at
  # acquisition (concurrency_duration, 3 min by default) and never refreshed,
  # so the dispatcher's maintenance loop reaps an expired lease even if the
  # holder is still running. A tick that runs longer than the lease loses its
  # exclusivity mid-run, and the next tick starts concurrently — the exact
  # double-dispatch this guard is meant to prevent. The real defense is
  # keeping every tick well under the lease by bounding both sweeps
  # (Event::RELAY_BATCH), so a backlog drains over several short ticks
  # instead of one long one. On Postgres, pg_try_advisory_xact_lock would be
  # a true lock; the lease here is the SQLite-era approximation.
  #
  # No-op under the :test adapter; the real behavior lives in Solid Queue's
  # Semaphore.
  limits_concurrency key: "event_relay", to: 1

  # Two recovery passes, both needed:
  #   - pass 1 (relay_stranded) re-drives events whose fanout was lost — a
  #     crash between commit and enqueue leaves zero delivery rows, so a
  #     delivery-only scan would never see it.
  #   - pass 2 (redeliver_stale) re-drives deliveries whose effect never
  #     landed — the job crashed, exhausted its retries, or got parked after
  #     enqueue, so dispatched_at looks fine while a subscriber quietly never ran.
  #
  # The notify call is the relay's liveness signal: a monitor alerts on its
  # absence, since Solid Queue only reports jobs that failed, not jobs that
  # never ran.
  def perform
    stranded = Event.relay_stranded
    redelivered, failed = Event::Delivery.redeliver_stale

    Rails.event.notify("event_relay.swept", stranded:, redelivered:, failed:)
  end
end
