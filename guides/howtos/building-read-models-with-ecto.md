# Building Read Models with Ecto Projections

Practical guide for common projection tasks. For conceptual understanding, see the [Ecto Projections explanation guide](../explanations/ecto-projections.html).

## Create a Basic Projection

**1. Define your read model schema:**

```elixir
defmodule MyApp.Accounts.Projections.Account do
  use Ecto.Schema

  schema "accounts" do
    field :account_number, :string
    field :balance, :integer
    
    timestamps()
  end
end
```

**2. Create the projector module:**

```elixir
defmodule MyApp.Accounts.Projectors.AccountProjector do
  use Commanded.Projections.Ecto,
    application: MyApp.Application,
    repo: MyApp.Repo,
    name: "account_projector"

  alias MyApp.Accounts.Projections.Account
  alias MyApp.Accounts.Events.{AccountOpened, MoneyDeposited}

  project %AccountOpened{account_number: number, initial_balance: balance}, fn multi ->
    Ecto.Multi.insert(multi, :account, %Account{
      account_number: number,
      balance: balance
    })
  end

  project %MoneyDeposited{account_number: number, amount: amount}, fn multi ->
    Ecto.Multi.update_all(
      multi,
      :account,
      where(Account, account_number: ^number),
      inc: [balance: ^amount]
    )
  end
end
```

**3. Add to your supervision tree:**

```elixir
children = [
  MyApp.Accounts.Projectors.AccountProjector
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Access Event Metadata

Use the 3-arity version of `project/3` to access metadata:

```elixir
project %OrderPlaced{order_id: id} = event, metadata, fn multi ->
  %{event_number: event_number, created_at: timestamp} = metadata
  
  Ecto.Multi.insert(multi, :order, %Order{
    id: id,
    event_number: event_number,
    placed_at: timestamp
  })
end
```

## Use Batch Processing for High Throughput

**Configure batch size:**

```elixir
defmodule MyApp.HighVolumeProjector do
  use Commanded.Projections.Ecto,
    application: MyApp.Application,
    repo: MyApp.Repo,
    name: "high_volume_projector",
    batch_size: 100
    
  # Use project_batch instead of project
  project_batch fn events, multi ->
    Enum.reduce(events, multi, fn
      {%EventA{id: id, data: data}, _metadata}, multi ->
        Ecto.Multi.insert(multi, {:event_a, id}, %ReadModel{
          id: id,
          data: data
        })
        
      {%EventB{id: id}, _metadata}, multi ->
        Ecto.Multi.update_all(multi, {:event_b, id}, 
          where(ReadModel, id: ^id),
          set: [processed: true]
        )
        
      _other, multi ->
        multi  # Ignore other events
    end)
  end
end
```

## Handle Multiple Tables in One Projection

Use `Ecto.Multi` operations:

```elixir
project %UserRegistered{user_id: id, email: email}, fn multi ->
  multi
  |> Ecto.Multi.insert(:user, %User{id: id, email: email})
  |> Ecto.Multi.insert(:audit, %AuditLog{
    action: "user_registered",
    user_id: id
  })
  |> Ecto.Multi.update_all(:stats, StatsQuery, inc: [user_count: 1])
end
```

## Handle Projection Errors

Implement the `error/3` callback:

```elixir
defmodule MyApp.ResilientProjector do
  use Commanded.Projections.Ecto,
    application: MyApp.Application,
    repo: MyApp.Repo,
    name: "resilient_projector"

  require Logger
  alias Commanded.Event.FailureContext

  # ... projection logic ...

  def error({:error, %Ecto.ConstraintError{}}, event, %FailureContext{}) do
    Logger.warning("Constraint violation, skipping event: #{inspect(event)}")
    :skip
  end

  def error({:error, reason}, event, %FailureContext{context: context}) do
    attempts = Map.get(context, :attempts, 0) + 1
    
    if attempts < 3 do
      Logger.warning("Projection failed, retrying (attempt #{attempts})")
      {:retry, 5_000, %{attempts: attempts}}
    else
      Logger.error("Projection failed after 3 attempts, skipping")
      :skip
    end
  end
end
```

## Notify After Projection Updates

Use the `after_update/3` callback for side effects:

```elixir
defmodule MyApp.NotifyingProjector do
  use Commanded.Projections.Ecto,
    application: MyApp.Application,
    repo: MyApp.Repo,
    name: "notifying_projector"

  # ... projection logic ...

  def after_update(event, metadata, _changes) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "projections",
      {:projection_updated, event, metadata}
    )
    
    :ok
  end
end
```

For batch projectors, use `after_update_batch/2`:

```elixir
def after_update_batch(events, _changes) do
  count = length(events)
  
  Phoenix.PubSub.broadcast(
    MyApp.PubSub,
    "projections",
    {:batch_projected, count}
  )
  
  :ok
end
```

## Configure Multi-Tenant Projections

**Option 1: Static schema prefix**

```elixir
use Commanded.Projections.Ecto,
  application: MyApp.Application,
  repo: MyApp.Repo,
  name: "tenant_a_projector",
  schema_prefix: "tenant_a"
```

**Option 2: Dynamic per-event prefix**

```elixir
use Commanded.Projections.Ecto,
  application: MyApp.Application,
  repo: MyApp.Repo,
  name: "multi_tenant_projector"

def schema_prefix(%_{tenant_id: tenant_id}, _metadata) do
  "tenant_#{tenant_id}"
end
```

**Option 3: Function-based prefix**

```elixir
use Commanded.Projections.Ecto,
  application: MyApp.Application,
  repo: MyApp.Repo,
  name: "function_prefix_projector",
  schema_prefix: fn event, _metadata -> 
    determine_schema(event)
  end
```

## Subscribe to Specific Streams

```elixir
use Commanded.Projections.Ecto,
  application: MyApp.Application,
  repo: MyApp.Repo,
  name: "account_projector",
  subscription_opts: [
    subscribe_to: "account-*",
    start_from: :origin
  ]
```

Or use top-level options:

```elixir
use Commanded.Projections.Ecto,
  application: MyApp.Application,
  repo: MyApp.Repo,
  name: "account_projector",
  subscribe_to: "account-*",
  start_from: :origin
```

## Rebuild a Projection

**1. Stop the projector**

**2. Delete the projection version:**

```sql
DELETE FROM projection_versions
WHERE projection_name = 'account_projector';
```

**3. Clear the read model tables:**

```sql
TRUNCATE TABLE accounts RESTART IDENTITY CASCADE;
```

**4. Reset the event store subscription:**

For EventStore adapter:

```elixir
MyApp.EventStore.delete_subscription("account_projector")
```

**5. Restart the projector**

The projector will replay all events from the beginning.

## Configure Runtime Options

Define projector without compile-time config:

```elixir
defmodule MyApp.RuntimeProjector do
  use Commanded.Projections.Ecto,
    repo: MyApp.Repo
    
  # ... projection logic ...
end
```

Start with runtime configuration:

```elixir
{:ok, pid} = MyApp.RuntimeProjector.start_link(
  application: MyApp.Application,
  name: "runtime_projector"
)
```

Or in supervision tree:

```elixir
children = [
  {MyApp.RuntimeProjector, 
   application: MyApp.Application, 
   name: "runtime_projector"}
]
```

## Skip Events Conditionally

Return the multi unchanged:

```elixir
project %ItemUpdated{id: id} = event, _metadata, fn multi ->
  case Repo.get(Item, id) do
    nil -> 
      multi  # Skip - item doesn't exist
      
    item -> 
      changeset = update_changeset(item, event)
      Ecto.Multi.update(multi, :item, changeset)
  end
end
```

## Common Options Reference

### Required Options

- `:application` - The Commanded application module
- `:name` - Unique projector name (string)
- `:repo` - Ecto repo module

### Subscription Options

- `:start_from` - `:origin`, `:current`, or event number
- `:subscribe_to` - `:all` or stream name/pattern

### Performance Options

- `:batch_size` - Number of events per transaction (integer)
- `:timeout` - Transaction timeout in milliseconds

### Schema Options

- `:schema_prefix` - String, 1-arity function, or 2-arity function

See the [Ecto Projections explanation guide](../explanations/ecto-projections.html) for architectural details and the moduledoc for complete API reference.
