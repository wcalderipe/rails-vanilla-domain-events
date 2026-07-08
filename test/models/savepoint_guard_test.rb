require "test_helper"

# Every guarded insert (create! rescued on RecordNotUnique) runs inside a
# savepoint. On SQLite these tests pass with or without the savepoint, because
# a failed statement does not poison the transaction; on PostgreSQL, without
# requires_new, each of these shapes raises InFailedSQLTransaction at the
# statement AFTER the rescue. The tests pin the shape so the savepoint cannot
# be optimized away without a failure on the engine where it matters.
class SavepointGuardTest < ActiveSupport::TestCase
  setup do
    @order = orders(:keyboard)
    Event.dispatch_after_create = false
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "publish_event's duplicate rescue survives inside a wider transaction" do
    existing = @order.publish_event("order.refund_requested", idempotence_key: "refund/1")

    ApplicationRecord.transaction do
      event = @order.publish_event("order.refund_requested", idempotence_key: "refund/1")

      assert_equal existing, event
      @order.update!(item: "keyboard pro")
    end

    assert_equal "keyboard pro", @order.reload.item
  end

  test "confirmation's duplicate rescue survives inside a wider transaction" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    Order::Confirmation.record(event)

    ApplicationRecord.transaction do
      confirmation = Order::Confirmation.record(event)

      assert confirmation.persisted?
      assert_equal Order::Confirmation.find_by(order_id: @order.id), confirmation
      orders(:mouse).update!(item: "mouse pro")
    end

    assert_equal "mouse pro", orders(:mouse).reload.item
    assert_equal 1, Order::Confirmation.where(order_id: @order.id).count
  end

  test "adjustment's duplicate rescue survives inside a wider transaction" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 2)
    applied = Inventory::Adjustment.apply(event)

    ApplicationRecord.transaction do
      adjustment = Inventory::Adjustment.apply(event)

      assert_equal applied, adjustment
      @order.update!(item: "keyboard pro")
    end

    assert_equal "keyboard pro", @order.reload.item
    assert_equal 1, Inventory::Adjustment.where(event_id: event.id).count
  end
end
