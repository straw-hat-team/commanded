if Code.ensure_loaded?(Ecto) do
  defmodule Commanded.Projections.Ecto do
    @moduledoc """
      Read model projections for Commanded using Ecto.

    Build read models (projections) from events in your Commanded application with
    automatic idempotency, transaction support, and optional batch processing.

    ## Basic Usage

        defmodule MyApp.Projectors.AccountProjector do
          use Commanded.Projections.Ecto,
            application: MyApp.Application,
            name: "account_projector",
            repo: MyApp.Repo

          project %AccountOpened{account_id: account_id, name: name}, _metadata, fn multi ->
            Ecto.Multi.insert(multi, :account, %Account{
              id: account_id,
              name: name,
              balance: 0
            })
          end

          project %MoneyDeposited{account_id: account_id, amount: amount}, _metadata, fn multi ->
            Ecto.Multi.update_all(
              multi,
              :account,
              where(Account, id: ^account_id),
              inc: [balance: ^amount]
            )
          end
        end

    ## Batch Processing

    Process multiple events in a single database transaction for improved throughput:

        defmodule MyApp.Projectors.HighVolumeBatchProjector do
          use Commanded.Projections.Ecto,
            application: MyApp.Application,
            name: "high_volume_batch_projector",
            repo: MyApp.Repo,
            batch_size: 50

          # Use project_batch/1 instead of project/3 for batch projectors
          project_batch fn events, multi ->
            # Process all events in a single transaction
            Enum.reduce(events, multi, fn
              {%EventA{id: id}, _metadata}, multi ->
                Ecto.Multi.insert(multi, {:event_a, id}, %ReadModel{...})

              {%EventB{id: id}, _metadata}, multi ->
                Ecto.Multi.update(multi, {:event_b, id}, ...)
            end)
          end
        end

    **Batch Limitations:**
    - Cannot use `:concurrency` option (mutually exclusive)
    - Only static `:schema_prefix` strings allowed (no dynamic functions)
    - Uses watermark-based idempotency for efficient batch processing

    ## Guides

    - [Getting started](ecto-projections-getting-started.html)
    - [Building read models](building-read-models-with-ecto.html)

    """

    @doc false
    def validate_mutual_exclusivity(opts) do
      batch_size = Keyword.get(opts, :batch_size)
      concurrency = Keyword.get(opts, :concurrency)

      case {batch_size, concurrency} do
        {nil, _} ->
          :ok

        {_, nil} ->
          :ok

        {_batch_size, _concurrency} ->
          {:error,
           "cannot use both :batch_size and :concurrency options - they are mutually exclusive. " <>
             "Use :batch_size for batch processing OR :concurrency for concurrent processing, but not both."}
      end
    end

    @doc false
    def validate_batch_schema_prefix_compatibility(batch_size, schema_prefix) do
      if batch_size && is_function(schema_prefix) do
        {:error,
         "cannot use :batch_size with dynamic :schema_prefix (function) - " <>
           "batch projectors only support static string prefixes. " <>
           "Either remove :batch_size or change :schema_prefix to a string."}
      else
        :ok
      end
    end

    defp __define_update_projection__ do
      quote do
        def update_projection(event, metadata, multi_fn) do
          projection_name = Map.fetch!(metadata, :handler_name)
          event_number = Map.fetch!(metadata, :event_number)

          projection_version = %ProjectionVersion{
            projection_name: projection_name,
            last_seen_event_number: event_number
          }

          prefix = schema_prefix(event, metadata)

          # Query to update an existing projection version with the last seen event number with
          # a check to ensure that the event has not already been projected.
          update_projection_version =
            from(pv in ProjectionVersion,
              where:
                pv.projection_name == ^projection_name and
                  pv.last_seen_event_number < ^event_number,
              update: [set: [last_seen_event_number: ^event_number]]
            )

          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.run(:track_projection_version, fn repo, _changes ->
              try do
                repo.insert(projection_version,
                  prefix: prefix,
                  on_conflict: update_projection_version,
                  conflict_target: [:projection_name]
                )
              rescue
                exception in Ecto.StaleEntryError ->
                  # Attempted to insert a projection version for an already seen event
                  {:error, :already_seen_event}

                exception ->
                  reraise exception, __STACKTRACE__
              end
            end)

          with %Ecto.Multi{} = multi <- multi_fn.(multi),
               {:ok, changes} <- transaction(multi) do
            if function_exported?(__MODULE__, :after_update, 3) do
              # credo:disable-for-next-line Credo.Check.Refactor.Apply
              apply(__MODULE__, :after_update, [event, metadata, changes])
            else
              :ok
            end
          else
            {:error, :track_projection_version, :already_seen_event, _changes} -> :ok
            {:error, _stage, error, _changes} -> {:error, error}
            {:error, _error} = reply -> reply
          end
        end
      end
    end

    defp __define_update_projection_batch__ do
      quote do
        def update_projection_batch([], _multi_fn) do
          # Empty batches are idempotent - nothing to process
          :ok
        end

        def update_projection_batch([{first_event, first_event_metadata} | _] = events, multi_fn)
            when is_map(first_event_metadata) and is_map_key(first_event_metadata, :handler_name) and
                   is_map_key(first_event_metadata, :event_number) do
          # Safe to use first event's handler_name for entire batch because:
          # All events in a batch come from the same handler process (received via {:events, events} message).
          # The handler enriches all events with its own handler_name when calling enrich_metadata/2.
          # It's architecturally impossible for events with different handler_name values to appear in the same batch.
          %{handler_name: projection_name} = first_event_metadata
          prefix = schema_prefix(first_event, first_event_metadata)

          multi = build_batch_projection_multi(events, projection_name, prefix)

          # Apply user's projection function and merge into our transaction
          execute_batch_projection(multi, multi_fn)
        end

        def update_projection_batch(invalid_batch, _multi_fn) do
          {:error,
           {:invalid_batch_format,
            "Expected list of {event, metadata} tuples, got: #{inspect(invalid_batch, limit: 3)}"}}
        end

        unquote(__define_batch_helpers__())
      end
    end

    defp __define_batch_helpers__ do
      quote do
        defp build_batch_projection_multi(events, projection_name, prefix) do
          Ecto.Multi.new()
          |> Ecto.Multi.run(:lock_and_filter, fn repo, _changes ->
            lock_and_filter_batch_events(repo, events, projection_name, prefix)
          end)
          |> Ecto.Multi.run(:track_projection_version, fn repo, %{lock_and_filter: result} ->
            track_batch_projection_version(repo, result, projection_name, prefix)
          end)
        end

        defp lock_and_filter_batch_events(repo, events, projection_name, prefix) do
          try do
            # Lock the projection_version row for this projector
            # This ensures no other process can update it concurrently
            current_last_seen =
              repo.one(
                from(pv in ProjectionVersion,
                  where: pv.projection_name == ^projection_name,
                  select: pv.last_seen_event_number,
                  lock: "FOR UPDATE"
                ),
                prefix: prefix
              ) || 0

            # Validate all events have required metadata fields
            invalid_events =
              Enum.reject(events, fn
                {_event, metadata} when is_map(metadata) ->
                  is_map_key(metadata, :event_number) and is_map_key(metadata, :handler_name)

                _ ->
                  false
              end)

            if invalid_events != [] do
              {:error,
               {:invalid_batch_structure,
                "All events must be {event, metadata} tuples with :event_number and :handler_name in metadata"}}
            else
              # Filter events based on FRESH data from inside the transaction
              unseen_events =
                Enum.filter(events, fn {_event, metadata} ->
                  metadata.event_number > current_last_seen
                end)

              case unseen_events do
                [] ->
                  # All events already seen
                  {:error, :already_seen_event}

                unseen_events ->
                  # Get last event in batch (events are guaranteed to be ordered by Commanded)
                  # Commanded's subscription always delivers events in ascending event_number order
                  {_last_event, last_metadata} = List.last(unseen_events)
                  %{event_number: last_unseen_number} = last_metadata

                  # Advance watermark to highest event number in this batch
                  # Provides defense-in-depth: ensures idempotency even if Commanded's
                  # subscription position is lost or corrupted during crash recovery
                  {:ok, {current_last_seen, unseen_events, last_unseen_number}}
              end
            end
          rescue
            exception ->
              reraise exception, __STACKTRACE__
          end
        end

        defp track_batch_projection_version(
               repo,
               {_current_last_seen, _unseen_events, last_event_number},
               projection_name,
               prefix
             ) do
          projection_version = %ProjectionVersion{
            projection_name: projection_name,
            last_seen_event_number: last_event_number
          }

          # Update watermark BEFORE user projection executes.
          # This is safe because we hold a FOR UPDATE lock from :lock_and_filter step:
          # 1. The lock ensures no other process can read or write this row until our
          #    transaction commits or rolls back, preventing all race conditions
          # 2. The conditional WHERE clause provides defense-in-depth:
          #    only batches with higher event_numbers can update the watermark
          # 3. If the user projection fails, the entire transaction rolls back atomically,
          #    including this watermark update, maintaining consistency
          # 4. The early update prevents wasted work in concurrent transactions
          #    that might be processing older events (they'll see the lock and wait)
          update_projection_version =
            from(pv in ProjectionVersion,
              where:
                pv.projection_name == ^projection_name and
                  pv.last_seen_event_number < ^last_event_number,
              update: [set: [last_seen_event_number: ^last_event_number]]
            )

          repo.insert(
            projection_version,
            prefix: prefix,
            on_conflict: update_projection_version,
            conflict_target: [:projection_name]
          )
        end

        defp execute_batch_projection(multi, multi_fn) do
          # This ensures EVERYTHING happens in ONE atomic transaction
          with %Ecto.Multi{} = multi <-
                 Ecto.Multi.run(multi, :prepare_user_multi, fn _repo,
                                                               %{
                                                                 lock_and_filter:
                                                                   {_current, unseen_events,
                                                                    _last}
                                                               } ->
                   user_multi = multi_fn.(unseen_events, Ecto.Multi.new())

                   case user_multi do
                     %Ecto.Multi{} ->
                       {:ok, {unseen_events, user_multi}}

                     other ->
                       {:error, {:invalid_multi_return, other}}
                   end
                 end),
               %Ecto.Multi{} = multi <-
                 Ecto.Multi.merge(multi, fn %{prepare_user_multi: {_unseen_events, user_multi}} ->
                   user_multi
                 end),
               {:ok, changes} <- transaction(multi) do
            # Get the unseen events from our preparation step
            {unseen_events, _user_multi} = changes.prepare_user_multi

            after_update_batch(unseen_events, changes)
          else
            {:error, :lock_and_filter, :already_seen_event, _changes} ->
              :ok

            {:error, _stage, error, _changes} ->
              {:error, error}

            {:error, _error} = reply ->
              reply
          end
        end
      end
    end

    defp __define_helper_functions__ do
      quote do
        def after_update(_event, _metadata, _changes), do: :ok
        def after_update_batch(_events, _changes), do: :ok

        defp transaction(%Ecto.Multi{} = multi) do
          @repo.transaction(multi, timeout: @timeout, pool_timeout: @timeout)
        end
      end
    end

    defmacro __using__(opts) do
      opts = opts || []
      batch_size = opts[:batch_size]

      schema_prefix =
        opts[:schema_prefix] ||
          Application.get_env(:commanded, Commanded.Projections.Ecto, [])
          |> Keyword.get(:schema_prefix)

      # Validate mutual exclusivity
      case validate_mutual_exclusivity(opts) do
        :ok -> :ok
        {:error, message} -> raise CompileError, description: message
      end

      # Validate batch schema prefix compatibility
      case validate_batch_schema_prefix_compatibility(batch_size, schema_prefix) do
        :ok -> :ok
        {:error, message} -> raise CompileError, description: message
      end

      quote location: :keep do
        @behaviour Commanded.Projections.Ecto

        @opts unquote(opts)
        @repo @opts[:repo] ||
                Application.compile_env(:commanded, [Commanded.Projections.Ecto, :repo]) ||
                raise("Commanded Ecto projections expects :repo to be configured in environment")
        @timeout @opts[:timeout] || :infinity

        # Pass through any other configuration to the event handler
        @handler_opts Keyword.drop(@opts, [:repo, :schema_prefix, :timeout])

        unquote(__include_schema_prefix__(schema_prefix))
        unquote(__include_projection_version_schema__())

        use Ecto.Schema
        use Commanded.Event.Handler, @handler_opts

        import Ecto.Query
        import unquote(__MODULE__)

        unquote(__define_update_projection__())
        unquote(__define_update_projection_batch__())
        unquote(__define_helper_functions__())

        defoverridable after_update: 3, after_update_batch: 2, schema_prefix: 1, schema_prefix: 2
      end
    end

    ## User callbacks

    @optional_callbacks [
      after_update: 3,
      after_update_batch: 2,
      schema_prefix: 1,
      schema_prefix: 2
    ]

    @doc """
    The optional `after_update/3` callback function defined in a projector is
    called after each projected event.

    The function receives the event, its metadata, and all changes from the
    `Ecto.Multi` struct that were executed within the database transaction.

    You could use this function to notify subscribers that the read model has been
    updated, such as by publishing changes via Phoenix PubSub channels.

    ## ⚠️ Transaction Semantics

    **CRITICAL:** This callback executes **AFTER** the database transaction has been
    committed. This means:

    - **Errors cannot rollback the transaction** - If this callback returns an error
      or raises an exception, the projection data is already persisted in the database.
    - **Use for side effects only** - This callback is designed for notifications,
      pub/sub, external API calls, or other side effects that should happen after
      successful projection updates.
    - **Error handling implications** - Returning `{:error, reason}` or raising an
      exception will propagate the error up, but the database changes are permanent.
      The event handler may retry, potentially causing duplicate side effects.

    If you need to perform validation or operations that should prevent the projection
    from being saved, do so within your `project/3` function (inside the `Ecto.Multi`),
    not in this callback.

    ## Example

        defmodule MyApp.ExampleProjector do
          use Commanded.Projections.Ecto,
            application: MyApp.Application,
            repo: MyApp.Projections.Repo,
            name: "MyApp.ExampleProjector"

          project %AnEvent{name: name}, _metadata, fn multi ->
            Ecto.Multi.insert(multi, :example_projection, %ExampleProjection{name: name})
          end

          @impl Commanded.Projections.Ecto
          def after_update(event, metadata, changes) do
            # Use the event, metadata, or `Ecto.Multi` changes and return `:ok`
            :ok
          end
        end

    """
    @callback after_update(event :: struct, metadata :: map, changes :: Ecto.Multi.changes()) ::
                :ok | {:ok, any} | {:error, any}

    @doc """
    The optional `after_update_batch/2` callback function defined in a projector is
    called after a batch of projected events.

    The function receives the events, their metadata, and all changes from the
    `Ecto.Multi` struct that were executed within the database transaction.

    ## ⚠️ Transaction Semantics

    **CRITICAL:** This callback executes **AFTER** the database transaction has been
    committed. This means:

    - **Errors cannot rollback the transaction** - If this callback returns an error
      or raises an exception, the projection data is already persisted in the database.
    - **Use for side effects only** - This callback is designed for notifications,
      pub/sub, external API calls, or other side effects that should happen after
      successful projection updates.
    - **Error handling implications** - Returning `{:error, reason}` or raising an
      exception will propagate the error up, but the database changes are permanent.
      The event handler may retry, potentially causing duplicate side effects.

    If you need to perform validation or operations that should prevent the projection
    from being saved, do so within your `project_batch/2` function (inside the
    `Ecto.Multi`), not in this callback.

    ## Example

        defmodule MyApp.ExampleProjector do
          use Commanded.Projections.Ecto,
            application: MyApp.Application,
            repo: MyApp.Projections.Repo,
            name: "MyApp.ExampleProjector",
            batch_size: 10

          project_batch fn events, multi ->
            Enum.reduce(events, multi, fn {event, _metadata}, multi ->
              # Process each event in the batch
              handle_event(event, multi)
            end)
          end

          @impl Commanded.Projections.Ecto
          def after_update_batch(events, changes) do
            # Use the events, metadata, or `Ecto.Multi` changes and return `:ok`
            :ok
          end
        end

    """
    @callback after_update_batch(events :: list(tuple), changes :: Ecto.Multi.changes()) ::
                :ok | {:error, any}

    @doc """
    The optional `schema_prefix/1` callback function defined in a projector is
    used to set the schema of the `projection_versions` table used by the
    projector for idempotency checks.

    It is passed the event and its metadata and must return the schema name, as a
    string, or `nil`.
    """
    @callback schema_prefix(event :: struct) :: String.t() | nil

    @doc """
    The optional `schema_prefix/2` callback function defined in a projector is
    used to set the schema of the `projection_versions` table used by the
    projector for idempotency checks.

    It is passed the event and its metadata, and must return the schema name, as a
    string, or `nil`
    """
    @callback schema_prefix(event :: struct(), metadata :: map()) :: String.t() | nil

    defp __include_schema_prefix__(schema_prefix) do
      quote do
        cond do
          is_nil(unquote(schema_prefix)) ->
            def schema_prefix(_event), do: nil
            def schema_prefix(event, _metadata), do: schema_prefix(event)

          is_binary(unquote(schema_prefix)) ->
            def schema_prefix(_event), do: unquote(schema_prefix)
            def schema_prefix(_event, _metadata), do: unquote(schema_prefix)

          is_function(unquote(schema_prefix), 1) ->
            def schema_prefix(event), do: apply(unquote(schema_prefix), [event])
            def schema_prefix(event, _metadata), do: apply(unquote(schema_prefix), [event])

          is_function(unquote(schema_prefix), 2) ->
            def schema_prefix(_event), do: nil

            def schema_prefix(event, metadata),
              do: apply(unquote(schema_prefix), [event, metadata])

          true ->
            raise ArgumentError,
              message:
                "expected :schema_prefix option to be a string or a one-arity or two-arity function, but got: " <>
                  inspect(unquote(schema_prefix))
        end
      end
    end

    defp __include_projection_version_schema__ do
      quote do
        defmodule ProjectionVersion do
          @moduledoc false
          use Ecto.Schema

          @primary_key {:projection_name, :string, []}

          schema "projection_versions" do
            field(:last_seen_event_number, :integer)

            timestamps(type: :naive_datetime_usec)
          end
        end
      end
    end

    @doc """
    Project a domain event into a read model by appending one or more operations
    to the `Ecto.Multi` struct passed to the projection function you define

    The operations will be executed in a database transaction including an
    idempotency check to guarantee an event cannot be projected more than once.

    ## Example

        project %AnEvent{}, fn multi ->
          Ecto.Multi.insert(multi, :my_projection, %MyProjection{...})
        end

    """
    defmacro project(event, lambda) do
      quote do
        def handle(unquote(event) = event, metadata) do
          update_projection(event, metadata, unquote(lambda))
        end
      end
    end

    @doc """
    Project a domain event and its metadata map into a read model by appending one
    or more operations to the `Ecto.Multi` struct passed to the projection
    function you define.

    The operations will be executed in a database transaction including an
    idempotency check to guarantee an event cannot be projected more than once.

    ## Example

        project %AnEvent{}, metadata, fn multi ->
          Ecto.Multi.insert(multi, :my_projection, %MyProjection{...})
        end

    """
    defmacro project(event, metadata, lambda) do
      quote do
        def handle(unquote(event) = event, unquote(metadata) = metadata) do
          update_projection(event, metadata, unquote(lambda))
        end
      end
    end

    @doc """
    Project a batch of domain events and their metadata into a read model by appending
    one or more operations to the `Ecto.Multi` struct passed to the projection function.

    This macro is used when `:batch_size` is configured. Events are received as a list
    of `{event, metadata}` tuples and processed in a single database transaction.

    The projection function receives two arguments:
    - `events`: List of `{event, metadata}` tuples
    - `multi`: An `Ecto.Multi` struct to build your projection operations

    ## Example

        project_batch fn events, multi ->
          Enum.reduce(events, multi, fn
            {%EventA{id: id}, _metadata}, multi ->
              Ecto.Multi.insert(multi, {:event_a, id}, %ReadModel{...})

            {%EventB{id: id}, _metadata}, multi ->
              Ecto.Multi.update(multi, {:event_b, id}, ...)
          end)
        end

    """
    defmacro project_batch(lambda) do
      quote do
        if Module.defines?(__MODULE__, {:handle_batch, 1}) do
          raise CompileError,
            description: """
            project_batch can only be called once per projector.

            To handle multiple event types, use pattern matching inside your handler:

                project_batch fn events, multi ->
                  Enum.reduce(events, multi, fn {event, metadata}, multi ->
                    case event do
                      %EventA{} -> ...
                      %EventB{} -> ...
                    end
                  end)
                end
            """
        end

        def handle_batch(all_events) do
          update_projection_batch(all_events, unquote(lambda))
        end
      end
    end
  end
end
