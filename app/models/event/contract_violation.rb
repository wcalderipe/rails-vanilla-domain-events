# Raised when a payload breaks the consumer's declared contract (missing key,
# wrong shape). Never transient, so never retried — fulfill turns it into a
# terminal failed delivery on the first execution.
class Event::ContractViolation < StandardError; end
