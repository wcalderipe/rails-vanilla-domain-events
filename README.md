# Rails Vanilla Domain Events

Durable domain events with a transactional outbox, in 79 lines of plain Rails: Active Record, a concern, Active Job, and a recurring job. No event gem, no broker.

This repo exists to make one argument, in the spirit of [Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/): before reaching for wisper, Kafka, or an eventing framework, check what the framework you already run gives you. Events as records (the Eventable pattern), fanned out to subscriber jobs, completed with a transactional outbox so no committed fact ever goes unannounced.

A guiding principle follows from that argument: lean on Rails and Solid Queue internals as far as they go (transactions, `after_create_commit`, `retry_on`, failed executions, recurring tasks) and only write code where the framework stops. Every line here answers a question the stack does not.

Domain: an `Order` you can place, pay, and ship. Paying records an `order.paid` event; two subscribers react (customer confirmation, inventory adjustment).

> [!WARNING]
> This is an experiment, not battle-tested production code. The mechanics are exercised by the test suite and the guided demo, but the pattern has not carried production traffic. Read it as a reference implementation to study and adapt, not as something to vendor in as-is.

## Run it

```sh
bin/setup --skip-server
bin/rails test
bin/demo        # the guided walkthrough: happy path, redelivery, crash gap, relay recovery
```

## How to read this README

Reliable eventing is a chain of questions, each one only askable once the previous is answered. This repo is organized as that chain: `main` states the problem and holds the naive starting point (`Rails.event.notify`, a log line and nothing more); each chapter lives on its own branch, takes the next question, changes the code to answer it, and extends this same document. This branch is chapter 1.

A question links to the branch that works on it; a question without a link has no chapter yet.

1. **Did we tell the queue? (📍 you're here)**
2. [Did the thing actually happen?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/2-did-the-thing-actually-happen)
3. [Which subscriber is actually done?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/3-which-subscriber-is-actually-done)
4. [Who guards the guard?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/4-who-guards-the-guard)
5. [Did we say it twice?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/5-did-we-say-it-twice)
6. [In what order do facts arrive?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/6-in-what-order-do-facts-arrive)
7. [What exactly did we say?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/7-what-exactly-did-we-say)
8. [How long do we remember?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/8-how-long-do-we-remember)
9. [What breaks when we leave SQLite?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/9-what-breaks-when-we-leave-sqlite)

## The problem

You committed a state change and need the rest of the system to react: send the confirmation, adjust inventory, sync a third party. The naive options all lose events:

- Inline callbacks couple the emitter to every listener and run side effects inside the request.
- Enqueueing a job per side effect at the call site scatters the fan-out across emitters, and a crash between the DB commit and the enqueue silently loses the reaction.
- In-memory pub/sub (wisper-style buses, `ActiveSupport::Notifications`) evaporates on any crash or restart: there is no record that the event ever happened.

The failure mode that matters is always the same dual write: the domain database commits, the queue never hears about it, and the missed side effect (an email never sent, access never granted) surfaces as a support ticket, not an error.

## Question 1: Did we tell the queue?

The fact is committed. Between that commit and the moment every subscriber job sits safely in the queue, there is a window where the process can die — and with it, the announcement. This question is what the transactional outbox answers, and everything on `main` exists to answer it: the guarantee provided here is **at-least-once enqueue**.

### The gap, precisely

Recording the event and telling the world about it are two writes:

1. `publish_event` inserts the `Event` row inside the domain transaction: the fact commits atomically with the state change it records. This part is durable by construction.
2. `after_create_commit` then enqueues one job per subscriber. This is the dual write: if the process dies between the commit and the enqueue (deploy restart, OOM kill), the fact exists but nobody ever reacts to it.

`after_create_commit` alone cannot close that gap; it can only make it rare. Worse, without a marker the failure is invisible: the stranded row looks like every other row, so nothing alerts you that a reaction never ran.

### How the outbox closes it

Two pieces on top of the plain Eventable pattern:

- A dispatch marker (`events.dispatched_at`). Fanout enqueues the subscriber jobs and then stamps the marker. A crash anywhere in between leaves `dispatched_at` null, which makes the stranded event detectable.
- A relay (`Event::RelayJob`, scheduled every minute in `config/recurring.yml`). It re-dispatches any undispatched event older than `Event::RELAY_AFTER`. This is the Message Relay / Polling Publisher half of the outbox pattern.

```mermaid
sequenceDiagram
  participant O as Order#pay
  participant DB as Domain DB
  participant Q as Solid Queue
  participant S as Subscriber jobs
  participant R as Event::RelayJob

  rect rgb(230, 245, 230)
    note over O,DB: one transaction (atomic)
    O->>DB: payment state record
    O->>DB: event row (publish_event)
  end

  DB-->>O: after_create_commit
  O->>Q: enqueue 1 job per subscriber
  O->>DB: stamp dispatched_at
  Q->>S: perform (retry_on, idempotent)

  note over O,Q: 💥 crash between commit and enqueue?<br/>fact persisted, dispatched_at stays null
  loop every minute
    R->>DB: stranded events (dispatched_at IS NULL, older than RELAY_AFTER)
    R->>Q: re-dispatch fanout
    R->>DB: stamp dispatched_at
  end
```

### The consequence: at-least-once, so consumers are idempotent

The relay re-runs the whole fanout (there is no per-subscriber delivery state), so a subscriber can see the same event more than once. Every consumer here is idempotent, showing the two standard shapes:

- Natural key: `Order::Confirmation` has a unique index on `order_id`; a replayed `order.paid` confirms nothing new.
- Event id dedup: `Inventory::Adjustment` has a unique index on `event_id`; the same event can never adjust stock twice. Stock is derived from adjustments (`Inventory.on_hand`), never counter-updated, so replays cannot drift it.

If subscribers multiply or need per-destination visibility, the next step is a delivery record per (event, subscriber): the `Webhook::Delivery` shape, which turns "redo the whole fanout" into "redo this delivery".

### Where the queue lives, and why it matters

This app uses Rails 8 defaults: Solid Queue in production with its own SQLite database (`queue` in `config/database.yml`), separate from the primary. Enqueue and domain commit therefore cannot share a transaction, which is exactly why the gap exists and the relay earns its place. Even an all-SQLite setup has the dual write.

If you point Solid Queue at the same database as the domain, you can enqueue inside the transaction and get atomicity for free: the marker + relay become unnecessary. Note the enqueue point has to move too — dispatch currently fires from `after_create_commit`, which by definition runs after the transaction; co-locating the databases alone does not close the gap. The pattern here is for every topology where that co-location is not true (separate queue DB, Redis-backed queues, a domain DB different from the queue DB) or not stable (you might split later).

### Design choices

| Choice | How it answers the question | Where |
|---|---|---|
| Atomic fact recording | The event row is inserted inside the domain transaction; the fact commits with the state change or not at all | `Eventable#publish_event`, `app/models/concerns/eventable.rb` |
| Lost fanout is detectable | Fanout stamps `dispatched_at` after enqueueing; a crash in between leaves it null instead of leaving silence | `Event#dispatch`, `app/models/event.rb` |
| Lost fanout is recovered | A recurring relay re-dispatches undispatched events older than `RELAY_AFTER` (the Polling Publisher half of the outbox pattern) | `Event::RelayJob`, `config/recurring.yml` |
| At-least-once delivery, made safe | The relay redoes the whole fanout, so consumers are idempotent by contract; both standard shapes are demonstrated | natural key: `Order::Confirmation` (unique on `order_id`); event-id dedup: `Inventory::Adjustment` (unique on `event_id`, stock derived by sum) |
| Subscriber isolation | One job per subscriber: a failing consumer never blocks the others | `Event#dispatch` fan-out |
| Decoupled emitters and listeners | A registry maps action to subscribers; events without listeners are still recorded, history does not depend on who listens | `Event.subscribe`, `config/initializers/event_subscriptions.rb` |
| Immutable history | The fact fields are `attr_readonly`; only the outbox bookkeeping (`dispatched_at`) stays writable | `app/models/event.rb` |
| Audit trail for free | The events table is readable history, ordered by emission (enabled by the design; no feed UI in this demo) | `Event` + `payload` |
| Replay and backfill | A new subscriber can be fed from the table by re-dispatching (enabled by the design; not wired in this demo) | re-dispatch over `Event` scopes |
| Deterministic crash testing | An internal seam turns off dispatch-after-create to simulate the crash between commit and fanout | `Event.dispatch_after_create`, used by tests and `bin/demo` |

Every choice is stock Rails — there is no library to learn and no broker to operate:

| Guarantee | Stock Rails feature that provides it |
|---|---|
| Fact commits atomically with the state change | Active Record transactions (`events.create!` inside the caller's transaction) |
| Fanout after the data is visible | `after_create_commit` |
| Failure visibility | Active Job + Solid Queue (failed executions) |
| The relay's schedule | Solid Queue recurring tasks (`config/recurring.yml`) |
| Append-only facts | `attr_readonly` |
| Consumer idempotency | unique indexes |

The trade is explicit: at-least-once delivery with idempotent consumers, instead of the exactly-once that no broker actually gives you anyway.

Notes on the shape of the code:

- `Event` is append-only on the domain side: `attr_readonly` on `eventable`, `action`, `payload`. `dispatched_at` is outbox bookkeeping, not part of the fact, so it stays writable.
- The fact and the reaction are decoupled by the registry (`config/initializers/event_subscriptions.rb`): events without subscribers are still recorded; history does not depend on who listens.
- `Event.dispatch_after_create` is an internal seam for tests and the demo: turning it off simulates the crash between commit and fanout deterministically.
- The interface is small (`publish_event`, `Event.subscribe`; the relay is invisible to callers); the outbox mechanics hide behind it. Deleting the mechanism would push dispatch bookkeeping into every emitting model, which is the deletion-test argument for keeping it a deep module.

## The next question: Did the thing actually happen?

Everything above guarantees the announcement, not the reaction. Once every subscriber's `perform_later` has returned and `dispatched_at` is stamped, the event is outside the relay's view — whether the subscriber job then succeeds, fails, or is discarded is invisible to the outbox. Answering that question is the next chapter, on the branch [`2-did-the-thing-actually-happen`](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/2-did-the-thing-actually-happen).
