# Rails Vanilla Domain Events

Durable domain events in plain Rails, built up chapter by chapter. No event gem, no bus framework, no message broker: Active Record, a concern, Active Job, and a recurring job carry the whole thing.

This repo exists to make one argument, in the spirit of [Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/): before reaching for wisper, Kafka, or an eventing framework, check what the framework you already run gives you.

A guiding principle follows from that argument: lean on Rails and Solid Queue internals as far as they go (transactions, `after_create_commit`, `retry_on`, failed executions, recurring tasks) and only write code where the framework stops. Every line added in the chapters answers a question the stack does not.

Domain: an `Order` you can place, pay, and ship.

> [!NOTE]
> This is a domain event system for reactions, not an event store. Its job is to let other parts of the system react to facts that already happened: send the confirmation, adjust inventory, sync a third party. It is not built to be the source of truth you rebuild state from. You could grow it into an event stream by adding replay and snapshotting, but that is a different system with different guarantees, and this repo does not go there.

> [!WARNING]
> This is an experiment, not battle-tested production code. The mechanics are exercised by the test suites on each chapter branch, but the pattern has not carried production traffic. Read it as a reference implementation to study and adapt, not as something to vendor in as-is.

## Run it

```sh
bin/setup --skip-server
bin/rails test
```

## How to read this repo

Reliable eventing is a chain of questions, each one only askable once the previous is answered. This repo is organized as that chain: `main` states the problem and holds the naive starting point; each chapter lives on its own branch, takes the next question, changes the code to answer it, and extends this same document.

A question links to the branch that works on it; a question without a link has no chapter yet.

1. [Did we tell the queue?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/1-did-we-tell-the-queue)
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

## Where main leaves you

This branch is the honest starting point. The domain works, and the models announce what happened the simplest way stock Rails offers, the structured event reporter:

```ruby
def pay
  transaction do
    create_payment!
    Rails.event.notify("order.paid", order_id: id, item:, quantity:, customer_email:)
  end
end
```

That buys observability: a structured log line, subscribable by log sinks, correlated by request. It buys nothing else. The notification is in-process and gone the moment it is emitted: no record that the event happened, nothing durable for a subscriber to react to, nothing to retry, nothing to replay. If the confirmation email matters, `Rails.event.notify` cannot be the mechanism that sends it.

Turning that log line into a fact the system can act on is the first question of the chain: [Did we tell the queue?](https://github.com/wcalderipe/rails-vanilla-domain-events/tree/1-did-we-tell-the-queue)

## The shortcut: enqueue the reactions directly

Before the event row and the subscriber registry, there is a shorter version worth taking seriously. Skip the indirection and enqueue the reactions straight from the transaction:

```ruby
def pay
  transaction do
    create_payment!
    Order::Confirmation.record_later(order)
    Inventory::Adjustment.apply_later(order)
  end
end
```

`record_later` and `apply_later` just enqueue a job; the synchronous counterparts are `record` and `apply`. No events table, no `Event.subscribe`. In the happy path it does the same work, and in one topology it is genuinely correct. It is worth knowing exactly where it stops.

The enqueue and the commit are two writes, and nothing here makes them one. With an external queue (Redis, or a separate database) `perform_later` does not join the payment's transaction, and both orderings break:

- Enqueue inside the transaction and the job is in the queue before the payment commits. A worker can pick it up and run against a payment that is not there yet. If the transaction then rolls back, the queue does not roll back with it: you have adjusted inventory and emailed a customer for an order that never happened.
- Enqueue after the commit (an `after_commit` hook, or Rails' `enqueue_after_transaction_commit`) and the race and the phantom job both disappear, but the crash window reopens: die between the commit and the enqueue and the reaction is lost with nothing to recover it.

No ordering escapes this. Before-commit gives phantom reactions on rollback; after-commit gives lost reactions on crash. The event row closes both, because the fact is written in the same transaction as the payment and a relay re-drives whatever fanout a crash dropped.

"But the queue is durable." It is. Once `perform_later` returns, Solid Queue keeps the job, retries it, and parks it in failed executions if it gives up. That is not the gap. The queue can only be durable about a job that exists, and the failure above is the one where no job was ever written. The outbox's durability is a different kind: it makes the record atomic with the domain write, so a committed payment with no record cannot happen. The queue's durability starts one step too late.

Two more things the durable queue does not give you:

- It couples paying to the queue being up. If the enqueue raises because the queue is unreachable, it raises inside the transaction and `pay` rolls back. Now you cannot take a payment because the mailer's queue is down. `publish_event` is a row in the database you are already writing, so paying depends only on the domain database.
- It is a worklist, not a log. A queue drains toward empty, and Solid Queue deletes finished jobs on a schedule. Once the confirmation and the adjustment have run, the record that `order.paid` happened is gone: no audit, no answer to "what happened last Tuesday," no replaying history into a subscriber you add next month. The events table is append-only history that outlives the reactions.

The one place the shortcut holds: put the queue in the same database as the domain and write the job row in the same transaction (co-located Solid Queue, in-transaction enqueue). Then the job commits atomically with the payment, no worker sees it before commit, and a rollback takes it too. That is the honest boundary of "vanilla Rails is plenty": the shortcut is correct exactly when the queue shares the transaction, and the moment it does not (Redis, a separate database, a connection of its own), you are back in the dual write the rest of this repo is about.
