class ApplicationJob < ActiveJob::Base
  # Retry jobs that hit a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Safe to discard if the underlying record is gone
  # discard_on ActiveJob::DeserializationError
end
