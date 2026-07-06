class Event::RelayJob < ApplicationJob
  queue_as :default

  def perform = Event.relay_stranded
end
