class ApplicationJob < ActiveJob::Base
  # These two are commented out by default in a generated Rails app. We enable
  # them here because:
  #   - Deadlocks are transient for every subscriber.
  #   - A subscriber job whose event row is gone can never succeed by retrying.
  retry_on ActiveRecord::Deadlocked

  discard_on ActiveJob::DeserializationError
end
