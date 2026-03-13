defmodule Commanded.TestSupport.MockEventStoreHelpers do
  @moduledoc """
  Named helpers for MockEventStore expectations.

  Replaces inline `expect`/`stub` calls with functions that describe the scenario
  under test. Each helper documents when and why to use it.
  """

  import Mox

  alias Commanded.EventStore.Adapters.Mock, as: MockEventStore
  alias Commanded.EventStore.RecordedEvent
  alias Commanded.UUID

  @doc """
  Apply the common MockEventStore stubs shared by MockEventStoreCase and
  MockProjectionCase. Centralizes adapter callback stubs so future changes
  are made in one place.
  """
  def stub_common_event_store do
    stub(MockEventStore, :ack_event, fn _meta, _pid, _event -> :ok end)

    stub(MockEventStore, :child_spec, fn _app, _cfg ->
      {:ok, [], %{}}
    end)

    stub(MockEventStore, :subscribe_to, fn _meta, _stream, _name, handler, _from, _opts ->
      send(handler, {:subscribed, self()})
      {:ok, self()}
    end)

    stub(MockEventStore, :subscribe, fn _meta, _stream -> :ok end)

    stub(MockEventStore, :append_to_stream, fn _meta, _uuid, _ver, _events, _opts ->
      :ok
    end)

    stub(MockEventStore, :stream_forward, fn _meta, _uuid, _from, _batch ->
      {:error, :stream_not_found}
    end)

    stub(MockEventStore, :read_snapshot, fn _meta, _uuid ->
      {:error, :snapshot_not_found}
    end)

    stub(MockEventStore, :record_snapshot, fn _meta, _snapshot -> :ok end)
    stub(MockEventStore, :delete_snapshot, fn _meta, _uuid -> :ok end)
    stub(MockEventStore, :unsubscribe, fn _meta, _sub -> :ok end)
    stub(MockEventStore, :delete_subscription, fn _meta, _stream, _name -> :ok end)

    :ok
  end

  @doc """
  Use for projection tests that send events directly via `send(projector, {:events, events})`.
  Returns `{:ok, self()}` without sending `{:subscribed, self()}` to the handler.
  This matches the original projection test setup and avoids Ecto Sandbox connection
  ownership issues when the handler processes events in a separate process.
  """
  def stub_subscribe_to_for_projections do
    stub(MockEventStore, :subscribe_to, fn _meta, _stream, _name, _handler, _from, _opts ->
      {:ok, self()}
    end)
  end

  @doc """
  Use when testing event handler `after_start/1` before the subscription is fully
  established. The default stub sends `{:subscribed, self()}` to the handler,
  which triggers subscription flow — this override returns `{:ok, handler}` so
  you can manually control when (or if) the handler receives the subscribed signal.
  """
  def stub_subscribe_to_return_handler do
    stub(MockEventStore, :subscribe_to, fn
      _event_store, :all, _handler_name, handler, _subscribe_from, _opts ->
        {:ok, handler}
    end)
  end

  @doc """
  Use when simulating a concurrency conflict: another process wrote to the stream
  before this append. The aggregate will retry (reload + append again) or give up.
  Pass `count:` when the aggregate retries multiple times.
  """
  def expect_append_wrong_expected_version(stream_uuid, opts \\ []) do
    count = Keyword.get(opts, :count, 1)

    expect(MockEventStore, :append_to_stream, count, fn _meta,
                                                        ^stream_uuid,
                                                        _exp_ver,
                                                        _events,
                                                        _opts ->
      {:error, :wrong_expected_version}
    end)
  end

  @doc """
  Use when the aggregate should persist events without conflict. Composes with
  `expect_stream_empty/2` for the typical happy path.
  """
  def expect_append_succeeds(stream_uuid, opts \\ []) do
    count = Keyword.get(opts, :count, 1)

    expect(MockEventStore, :append_to_stream, count, fn _meta,
                                                        ^stream_uuid,
                                                        _exp_ver,
                                                        _events,
                                                        _opts ->
      :ok
    end)
  end

  @doc """
  Use when the aggregate loads from an empty stream (new aggregate or no events
  after a given version). The default stub returns `{:error, :stream_not_found}`;
  this returns `[]` so the aggregate treats it as "no events" rather than missing.
  """
  def expect_stream_empty(stream_uuid, opts \\ []) do
    count = Keyword.get(opts, :count, 1)

    expect(MockEventStore, :stream_forward, count, fn _meta, ^stream_uuid, _from, _batch_size ->
      []
    end)
  end

  @doc """
  Use when testing load telemetry for a brand-new aggregate. The stream does not
  exist yet, so the aggregate gets `stream_not_found` and never calls populate.
  """
  def expect_stream_not_found(stream_uuid) do
    expect(MockEventStore, :stream_forward, fn _meta, ^stream_uuid, _from, _batch_size ->
      {:error, :stream_not_found}
    end)
  end

  @doc """
  Use when the aggregate should load existing events (e.g. reload after restart).
  Pass a list of `RecordedEvent`s — build them with `build_recorded_event/4`.
  """
  def expect_stream_with_events(stream_uuid, events, opts \\ []) do
    count = Keyword.get(opts, :count, 1)

    expect(MockEventStore, :stream_forward, count, fn _meta, ^stream_uuid, _from, _batch_size ->
      events
    end)
  end

  @doc """
  Use when testing that the aggregate gives up after a concurrency conflict
  (e.g. telemetry for `wrong_expected_version`, or `:too_many_attempts`). Append
  fails, reload finds nothing new, append fails again — aggregate stops retrying.
  """
  def expect_wrong_expected_version_conflict(stream_uuid) do
    expect_append_wrong_expected_version(stream_uuid)
    expect_stream_empty(stream_uuid, count: 2)
  end

  @doc """
  Use when the aggregate should succeed on first try: new stream, no concurrent
  writes. Covers the common "create aggregate and append first event" scenario.
  """
  def expect_successful_append_with_empty_stream(stream_uuid) do
    expect_append_succeeds(stream_uuid)
    expect_stream_empty(stream_uuid)
  end

  @doc """
  Use when setting up an aggregate that already has one event (e.g. `OpenAccount`).
  Stream is empty from version 1 onward; the first append at version 0 succeeds.
  Call before `Supervisor.open_aggregate/3` and the first `Aggregate.execute/4`.
  """
  def expect_open_aggregate(stream_uuid) do
    expect(MockEventStore, :stream_forward, fn _meta, ^stream_uuid, 1, _batch_size ->
      []
    end)

    expect(MockEventStore, :append_to_stream, fn _meta, ^stream_uuid, 0, _events, _opts ->
      :ok
    end)
  end

  @doc """
  Use when testing that the aggregate retries and wins after a conflict. First
  append fails; reload discovers the concurrent event; second append succeeds.
  Pass the event that "another process" wrote — the aggregate will incorporate it.
  """
  def expect_concurrency_retry_succeeds(stream_uuid, concurrent_event) do
    expect(MockEventStore, :append_to_stream, fn _meta, ^stream_uuid, 1, _events, _opts ->
      {:error, :wrong_expected_version}
    end)

    expect(MockEventStore, :stream_forward, fn _meta, ^stream_uuid, 2, _batch_size ->
      [concurrent_event]
    end)

    expect(MockEventStore, :append_to_stream, fn _meta, ^stream_uuid, 2, _events, _opts ->
      :ok
    end)
  end

  @doc """
  Use when testing retry-after-conflict where the aggregate reloads, applies the
  discovered event, and appends successfully. First append fails; stream returns
  [] then [event]; second append succeeds. Use for telemetry or span tests that
  assert on `wrong_expected_version` count when retry wins.
  """
  def expect_wrong_expected_version_retry_succeeds(stream_uuid, event, opts \\ []) do
    reload_version = Keyword.get(opts, :reload_version, 1)

    expect(MockEventStore, :append_to_stream, 2, fn
      _meta, ^stream_uuid, 0, _events, _opts ->
        {:error, :wrong_expected_version}

      _meta, ^stream_uuid, ^reload_version, _events, _opts ->
        :ok
    end)

    stream_forward_calls = :counters.new(1, [])

    expect(MockEventStore, :stream_forward, 2, fn _meta,
                                                  ^stream_uuid,
                                                  ^reload_version,
                                                  _batch_size ->
      n = :counters.get(stream_forward_calls, 1)
      :counters.add(stream_forward_calls, 1, 1)

      if n == 0 do
        []
      else
        [event]
      end
    end)
  end

  @doc """
  Use when testing that the aggregate stops after exhausting retries. Append
  keeps failing, reload finds nothing — aggregate returns `:too_many_attempts`.
  Pass `count:` to match the aggregate's `retry_attempts` (default 6).
  """
  def expect_too_many_retry_attempts(stream_uuid, opts \\ []) do
    count = Keyword.get(opts, :count, 6)
    expect_append_wrong_expected_version(stream_uuid, count: count)
    expect_stream_empty(stream_uuid, count: count)
  end

  @doc """
  Build a `RecordedEvent` for `expect_stream_with_events/3` or
  `expect_concurrency_retry_succeeds/2`. Pass stream id, event number, and the
  domain event struct; use `event_type:` when the inferred type is wrong.
  """
  def build_recorded_event(stream_uuid, event_number, data, opts \\ []) do
    defaults = [
      event_id: UUID.uuid4(),
      event_number: event_number,
      stream_id: stream_uuid,
      stream_version: event_number,
      correlation_id: nil,
      causation_id: nil,
      event_type: infer_event_type(data),
      data: data,
      metadata: %{},
      created_at: DateTime.utc_now()
    ]

    struct!(RecordedEvent, Keyword.merge(defaults, opts))
  end

  defp infer_event_type(%{__struct__: struct}), do: to_string(struct)
  defp infer_event_type(_), do: "Elixir.Commanded.EventStore.RecordedEvent"
end
