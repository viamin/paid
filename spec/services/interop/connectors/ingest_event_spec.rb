# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Connectors::IngestEvent do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) do
      create(:project, account: account, interop_settings: {
        "adoption_mode" => "advisory",
        "connectors" => { "jira" => true },
        "external_execution_sources" => {}
      })
    end

    it "creates a processed connector event" do
      event = described_class.call(
        project: project,
        connector_key: "jira",
        event_type: "issue_created",
        payload: { "issue" => { "key" => "PROJ-1" } },
        external_event_id: "jira-event-001"
      )

      expect(event).to be_persisted
      expect(event.connector_key).to eq("jira")
      expect(event.event_type).to eq("issue_created")
      expect(event.status).to eq("processed")
      expect(event.external_event_id).to eq("jira-event-001")
    end

    it "stores normalized data from the connector" do
      event = described_class.call(
        project: project,
        connector_key: "jira",
        event_type: "issue_created",
        payload: {
          "issue" => {
            "key" => "PROJ-42",
            "fields" => { "summary" => "Test issue" }
          }
        },
        external_event_id: "jira-event-002"
      )

      expect(event.normalized_data["external_id"]).to eq("PROJ-42")
      expect(event.normalized_data["title"]).to eq("Test issue")
    end

    it "rejects unknown connector keys" do
      expect {
        described_class.call(
          project: project,
          connector_key: "unknown_connector",
          event_type: "test",
          payload: {},
          external_event_id: "x-1"
        )
      }.to raise_error(ArgumentError, /unknown connector/)
    end

    it "rejects connectors that are not enabled on the project" do
      expect {
        described_class.call(
          project: project,
          connector_key: "slack",
          event_type: "message_posted",
          payload: {},
          external_event_id: "slack-1"
        )
      }.to raise_error(ArgumentError, /not enabled/)
    end

    it "rejects duplicate external event IDs for the same project" do
      described_class.call(
        project: project,
        connector_key: "jira",
        event_type: "issue_created",
        payload: {},
        external_event_id: "jira-dup-001"
      )

      expect {
        described_class.call(
          project: project,
          connector_key: "jira",
          event_type: "issue_updated",
          payload: {},
          external_event_id: "jira-dup-001"
        )
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
