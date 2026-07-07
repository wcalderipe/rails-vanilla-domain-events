# Rails Vanilla Domain Events

Durable domain events in plain Rails, built up chapter by chapter. No event gem, no bus framework, no message broker: Active Record, a concern, Active Job, and a recurring job carry the whole thing.

This repo exists to make one argument, in the spirit of [Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/): before reaching for wisper, Kafka, or an eventing framework, check what the framework you already run gives you.

A guiding principle follows from that argument: lean on Rails and Solid Queue internals as far as they go (transactions, `after_create_commit`, `retry_on`, failed executions, recurring tasks) and only write code where the framework stops. Every line added in the chapters answers a question the stack does not.

Domain: an `Order` you can place, pay, and ship.

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
8. How long do we remember?
9. What breaks when we leave SQLite?

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
