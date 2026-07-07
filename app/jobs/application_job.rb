class ApplicationJob < ActiveJob::Base
  # The two suggestions every generated Rails app ships commented out,
  # enabled because chapter 2 makes them load-bearing: deadlocks are the
  # one error transient for every subscriber, and a subscriber job whose
  # event row is gone can never succeed by retrying.
  retry_on ActiveRecord::Deadlocked

  discard_on ActiveJob::DeserializationError
end
