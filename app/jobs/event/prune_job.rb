class Event::PruneJob < ApplicationJob
  queue_as :default

  # Runs daily to enforce retention. The notify call mirrors the relay's
  # liveness signal — a monitor alerts if it goes missing.
  def perform
    pruned = Event.prune

    Rails.event.notify("event_prune.swept", pruned:)
  end
end
