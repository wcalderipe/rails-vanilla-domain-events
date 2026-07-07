class Event::PruneJob < ApplicationJob
  queue_as :default

  # Retention enforcement, daily. The notify line mirrors the relay's
  # liveness signal: a monitor alerts on its absence.
  def perform
    pruned = Event.prune

    Rails.event.notify("event_prune.swept", pruned:)
  end
end
