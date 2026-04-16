defmodule Commanded.EventStore.RecordedEventTest do
  use ExUnit.Case

  alias Commanded.EventStore.AdapterTestData
  alias Commanded.EventStore.EnrichedMetadata
  alias Commanded.EventStore.RecordedEvent

  setup do
    [event] =
      AdapterTestData.build_recorded_events(
        [AdapterTestData.build_opened_event(account_number: "123")],
        1,
        metadata: %{"key1" => "value1", "key2" => "value2"}
      )

    [event: event]
  end

  describe "RecordedEvent struct" do
    test "enrich_metadata/2 should add a number of fields to the metadata", %{event: event} do
      %RecordedEvent{
        event_id: event_id,
        event_number: event_number,
        stream_id: stream_id,
        stream_version: stream_version,
        correlation_id: correlation_id,
        causation_id: causation_id,
        created_at: created_at
      } = event

      enriched_metadata =
        RecordedEvent.enrich_metadata(event,
          additional_metadata: %{
            application: ExampleApplication
          }
        )

      assert %EnrichedMetadata{
               event_id: ^event_id,
               event_number: ^event_number,
               stream_id: ^stream_id,
               stream_version: ^stream_version,
               correlation_id: ^correlation_id,
               causation_id: ^causation_id,
               created_at: ^created_at,
               application: ExampleApplication,
               handler_name: nil,
               state: nil,
               metadata: %{"key1" => "value1", "key2" => "value2"}
             } = enriched_metadata
    end

    test "keeps explicit event ids when mapping recorded events" do
      transfer_uuid = Commanded.UUID.uuid4()

      [event] =
        AdapterTestData.build_recorded_events([
          AdapterTestData.build_deposited_event(
            account_number: "123",
            transfer_uuid: transfer_uuid
          )
        ])

      assert event.event_id == transfer_uuid
      assert event.data.transfer_uuid == transfer_uuid
    end
  end
end
