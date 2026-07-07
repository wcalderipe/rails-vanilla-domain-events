class Event::Delivery < ApplicationRecord
  MAX_ATTEMPTS = 5

  # A pending delivery quiet for this long is treated as lost — its job
  # crashed, was parked, or exhausted its own Active Job retries — and is
  # re-driven. The window sits ABOVE the subscribers' retry_on backoff window
  # (chapter 2) on purpose: while a subscriber is still backing off, each
  # execution refreshes updated_at (fulfill) and each re-enqueue touches it
  # (deliver_later), so an actively-recovering delivery never looks stale. Tier
  # 2 wakes only for deliveries that have gone genuinely quiet — a safety net,
  # not a second retry loop competing with the first.
  REDELIVER_AFTER = 15.minutes

  belongs_to :event

  scope :pending, -> { where(delivered_at: nil, failed_at: nil) }
  scope :stale, -> { pending.where(updated_at: ..REDELIVER_AFTER.ago) }

  # Tier 2 of the relay: re-drives deliveries whose effect never landed.
  # Exhausting MAX_ATTEMPTS is a terminal transition, not another loop:
  # the delivery fails and the failure is reported, so a permanently broken
  # subscriber pages a human instead of retrying forever.
  def self.redeliver_stale
    stale.find_each do |delivery|
      if delivery.attempts >= MAX_ATTEMPTS
        delivery.mark_failed(error: "redelivery attempts exhausted")
      else
        delivery.deliver_later
      end
    end
  end

  # Enqueue, then refresh the staleness clock — in that order, and note what is
  # NOT here: attempts is not bumped. attempts counts executions, not enqueues
  # (fulfill owns it), so a queue outage or an overlapping relay can re-enqueue
  # freely without ever spending the retry budget against a delivery that has
  # not run — the loss the old enqueue-counting accounting produced.
  #
  # The touch AFTER a successful enqueue is what keeps the relay's two tiers
  # from re-driving the same delivery in one tick: tier 1 re-enqueues and
  # touches, so tier 2 (which runs next) no longer sees it as stale. (increment!
  # alone would not do this — by default it bumps the counter WITHOUT touching
  # updated_at.) A failed enqueue skips the touch, so the next sweep retries it
  # promptly instead of waiting out another window.
  def deliver_later
    subscriber.constantize.perform_later(self)
    touch
  end

  # Runs when the job actually executes — the honest place to spend an attempt.
  # increment! is OUTSIDE the effect's transaction so a rolled-back effect still
  # counts (a subscriber that runs and fails burned an attempt); touch: true so
  # every execution also refreshes updated_at, keeping a retrying delivery out
  # of the stale window while its own retry_on is still working.
  def fulfill
    return if terminal?

    increment!(:attempts, touch: true)

    transaction do
      yield event
      update!(delivered_at: Time.current)
    end
  end

  # Terminal only if the effect has not already landed. The guarded re-check
  # under a row lock stops a tier-2 exhaustion from stamping failed_at on a row
  # that a subscriber job delivered concurrently — otherwise the delivery would
  # carry both timestamps and page a human for work that in fact succeeded.
  def mark_failed(error:)
    newly_failed = with_lock do
      next false if terminal?
      update!(failed_at: Time.current, error: error)
      true
    end

    return unless newly_failed

    Rails.error.report(RuntimeError.new("event delivery failed: #{error}"),
                       context: { delivery_id: id, event_id: event_id, subscriber: subscriber })
  end

  def terminal? = delivered_at.present? || failed_at.present?
  def delivered? = delivered_at.present?
  def failed? = failed_at.present?
end
