class Event::RelayJob < ApplicationJob
  queue_as :default

  # Two passes, both needed.
  #   - Pass 1 (relay_stranded) re-drives events whose fanout was lost — e.g.
  #     a crash between commit and enqueue leaves zero delivery rows, so a
  #     delivery-only scan would never find it.
  #   - Pass 2 (redeliver_stale) re-drives deliveries whose effect never
  #     landed — e.g. the job crashed, exhausted its retries, or got stuck
  #     after enqueue. Without it, dispatched_at would say everything worked
  #     while a subscriber quietly never ran.
  def perform
    Event.relay_stranded
    Event::Delivery.redeliver_stale
  end
end
