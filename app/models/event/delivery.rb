class Event::Delivery < ApplicationRecord
  MAX_ATTEMPTS = 5

  # A pending delivery quiet this long is treated as lost — its job crashed,
  # got parked, or exhausted its own Active Job retries — and gets re-driven.
  # This window sits above the subscribers' retry_on backoff window (chapter
  # 2) on purpose: while a subscriber is still backing off, each execution
  # refreshes updated_at (fulfill) and each re-enqueue touches it
  # (deliver_later), so an actively-recovering delivery never looks stale.
  # Pass 2 only wakes for deliveries that have gone genuinely quiet — a
  # safety net, not a second retry loop competing with the first.
  REDELIVER_AFTER = 15.minutes

  belongs_to :event

  scope :pending, -> { where(delivered_at: nil, failed_at: nil) }
  scope :stale, -> { pending.where(updated_at: ..REDELIVER_AFTER.ago) }

  # Pass 2 of the relay (see Event::RelayJob): re-drives deliveries whose
  # effect never landed. Exhausting MAX_ATTEMPTS is a terminal transition,
  # not another loop: the delivery fails and the failure is reported, so a
  # permanently broken subscriber pages a human instead of retrying forever.
  # Rescued per item, so one bad delivery can't abort the sweep for
  # everything behind it. Returns [redelivered, failed] counts for the
  # relay's liveness signal.
  def self.redeliver_stale
    redelivered = failed = 0

    # Bounded and oldest-first, same as pass 1 (Event::RELAY_BATCH): a tick
    # must stay short enough not to outrun the relay's concurrency lease.
    stale.order(:updated_at).limit(Event::RELAY_BATCH).each do |delivery|
      if delivery.attempts >= MAX_ATTEMPTS
        delivery.mark_failed(error: "redelivery attempts exhausted")
        failed += 1
      else
        delivery.deliver_later
        redelivered += 1
      end
    rescue StandardError => error
      Rails.error.report(error, context: { delivery_id: delivery.id, subscriber: delivery.subscriber })
    end

    [ redelivered, failed ]
  end

  # Age of the oldest delivery still waiting for its effect, in seconds; nil
  # if nothing is pending. This is the relay's health reading: if it grows
  # past the sweep interval, the guard is asleep.
  def self.oldest_pending_age
    oldest = pending.minimum(:updated_at)
    oldest && Time.current - oldest
  end

  # Enqueue, then refresh the staleness clock — in that order. Note what's
  # NOT here: attempts isn't bumped. attempts counts executions, not
  # enqueues (fulfill owns that), so a queue outage or an overlapping relay
  # can re-enqueue freely without spending the retry budget on a delivery
  # that hasn't even run — the bug the old enqueue-counting approach had.
  #
  # Touching updated_at only after a successful enqueue is what keeps the
  # relay's two passes from re-driving the same delivery in one tick: pass 1
  # re-enqueues and touches, so pass 2 (which runs next) no longer sees it as
  # stale. (increment! alone wouldn't do this — by default it bumps the
  # counter without touching updated_at.) A failed enqueue skips the touch,
  # so the next sweep retries it promptly instead of waiting out another window.
  def deliver_later
    subscriber.constantize.perform_later(self)
    touch
  end

  # Runs when the job actually executes — the honest place to spend an
  # attempt. increment! happens outside the effect's transaction so a
  # rolled-back effect still counts (a subscriber that ran and failed burned
  # an attempt); touch: true so every execution also refreshes updated_at,
  # keeping a retrying delivery out of the stale window while its own
  # retry_on is still working.
  def fulfill
    return if terminal?

    increment!(:attempts, touch: true)

    transaction do
      yield event
      update!(delivered_at: Time.current)
    end
  end

  # Terminal only if the effect hasn't already landed. The guarded re-check
  # under a row lock stops a pass-2 exhaustion from stamping failed_at on a
  # row that a subscriber job delivered concurrently — otherwise the
  # delivery would carry both timestamps and page a human for work that
  # actually succeeded.
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
