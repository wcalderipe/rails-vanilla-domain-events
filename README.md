# Outbox Demo

A minimal Rails 8 + SQLite app demonstrating the **Eventable pattern completed with a transactional outbox**: domain events as durable records, fanned out to subscriber jobs, with a relay that recovers events whose fanout was lost.

Domain: an `Order` you can place, pay, and ship. Paying records an `order.paid` event; two subscribers react (customer confirmation, inventory adjustment).

## Run it

```sh
bin/setup --skip-server
bin/rails test
bin/demo        # the guided walkthrough: happy path, redelivery, crash gap, relay recovery
```

## The problem this closes

Recording the event and telling the world about it are two writes:

1. `track_event` inserts the `Event` row **inside the domain transaction**: the fact commits atomically with the state change it records. This part is durable by construction.
2. `after_create_commit` then enqueues one job per subscriber. This is a **dual write**: if the process dies between the commit and the enqueue (deploy restart, OOM kill, crash), the fact exists but nobody ever reacts to it.

`after_create_commit` alone cannot close that gap; it can only make it rare. Worse, without a marker the failure is **invisible**: the row looks like every other row, and the missed side effect (an email never sent, access never granted) surfaces as a support ticket, not an error.

## How the outbox closes it

Two pieces on top of the plain Eventable pattern:

- **A dispatch marker** (`events.dispatched_at`). Fanout enqueues the subscriber jobs and then stamps the marker. A crash anywhere in between leaves `dispatched_at` null, which makes the stranded event *detectable*.
- **A relay** (`Event::RelayJob`, scheduled every minute in `config/recurring.yml`). It re-dispatches any undispatched event older than `Event::RELAY_AFTER`, so no committed fact stays unannounced. This is the Message Relay / Polling Publisher half of the outbox pattern.

```
domain tx:   [ state change + event row ]        -- atomic
post-commit: enqueue jobs, set dispatched_at     -- can fail, detectable
relay:       every minute, re-dispatch stranded  -- closes the gap
```

## The consequence: at-least-once, so consumers are idempotent

The relay re-runs the **whole** fanout (there is no per-subscriber delivery state), so a subscriber can see the same event more than once. Every consumer here is idempotent, showing the two standard shapes:

- **Natural key**: `Order::Confirmation` has a unique index on `order_id`; a replayed `order.paid` confirms nothing new.
- **Event id dedup**: `Inventory::Adjustment` has a unique index on `event_id`; the same event can never adjust stock twice. Stock is *derived* from adjustments (`Inventory.on_hand`), never counter-updated, so replays cannot drift it.

If subscribers multiply or need per-destination visibility, the next step is a delivery record per (event, subscriber): the `Webhook::Delivery` shape, which turns "redo the whole fanout" into "redo this delivery".

## Where the queue lives, and why it matters

This app uses Rails 8 defaults: Solid Queue in production with its **own** SQLite database (`queue` in `config/database.yml`), separate from the primary. Enqueue and domain commit therefore **cannot share a transaction**, which is exactly why the gap exists and the relay earns its place. Even an all-SQLite setup has the dual write.

If you point Solid Queue at the **same** database as the domain, you can enqueue *inside* the transaction and get atomicity for free: the marker + relay become unnecessary. The pattern here is for every topology where that co-location is not true (separate queue DB, Redis-backed queues, a domain DB different from the queue DB) or not stable (you might split later).

## Design notes

- `Event` is append-only on the domain side: `attr_readonly` on `eventable`, `action`, `payload`. `dispatched_at` is outbox bookkeeping, not part of the fact, so it stays writable.
- The fact and the reaction are decoupled by the registry (`config/initializers/event_subscriptions.rb`): events without subscribers are still recorded; history does not depend on who listens.
- `Event.dispatch_after_create` exists as an internal seam for tests and the demo: turning it off simulates the crash between commit and fanout deterministically.
- The interface is small (`track_event`, `Event.subscribe`; the relay is invisible to callers); the outbox mechanics hide behind it. Deleting the mechanism would push dispatch bookkeeping into every emitting model, which is the deletion-test argument for keeping it a deep module.
