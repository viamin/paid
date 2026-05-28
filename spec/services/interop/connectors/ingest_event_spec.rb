# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Connectors::IngestEvent do
  describe ".call" do
    let(:account) { create(:account) }
    let(:slack_payload) { { "event" => { "ts" => "123.456", "type" => "message", "text" => "hi" } } }
    let(:slack_raw_body) do
      '{"connector_event":{"connector_key":"slack","event_type":"message_posted","external_event_id":"slack-1","payload":{"event":{"ts":"123.456","type":"message","text":"hi"}}}}'
    end
    let(:slack_timestamp) { Time.current.to_i.to_s }
    let(:slack_signature) do
      digest = OpenSSL::HMAC.hexdigest("SHA256", "signing-secret", "v0:#{slack_timestamp}:#{slack_raw_body}")
      "v0=#{digest}"
    end
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

    it "allows duplicate external event IDs across different connectors in one project" do
      described_class.call(
        project: project,
        connector_key: "jira",
        event_type: "issue_created",
        payload: {},
        external_event_id: "shared-event-id"
      )

      project.update!(interop_settings: project.interop_settings.merge("connectors" => { "jira" => true, "linear" => true }))

      event = described_class.call(
        project: project,
        connector_key: "linear",
        event_type: "issue_updated",
        payload: {},
        external_event_id: "shared-event-id"
      )

      expect(event).to be_persisted
      expect(event.connector_key).to eq("linear")
    end

    it "rejects connector ingestion when adoption mode does not permit it" do
      project.update!(interop_settings: project.interop_settings.merge("adoption_mode" => "observe_only"))

      expect {
        described_class.call(
          project: project,
          connector_key: "jira",
          event_type: "issue_created",
          payload: {},
          external_event_id: "jira-observe-only"
        )
      }.to raise_error(ArgumentError, /receive_connector_events is not permitted/)
    end

    it "verifies Slack signatures against the raw body and request timestamp header" do
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "connectors" => { "slack" => true },
        "external_execution_sources" => {}
      })

      event = described_class.call(
        project: project,
        connector_key: "slack",
        event_type: "message_posted",
        payload: slack_payload,
        external_event_id: "slack-1",
        signature: slack_signature,
        secret: "signing-secret",
        raw_body: slack_raw_body,
        request_headers: { "X-Slack-Request-Timestamp" => slack_timestamp }
      )

      expect(event).to be_persisted
      expect(event.status).to eq("processed")
    end

    it "rejects signed connectors when the request is missing a signature" do
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "connectors" => { "slack" => true },
        "external_execution_sources" => {}
      })

      expect {
        described_class.call(
          project: project,
          connector_key: "slack",
          event_type: "message_posted",
          payload: slack_payload,
          external_event_id: "slack-missing-signature",
          secret: "signing-secret",
          raw_body: slack_raw_body,
          request_headers: { "X-Slack-Request-Timestamp" => slack_timestamp }
        )
      }.to raise_error(ArgumentError, /signature is required for slack/)
    end

    it "rejects Slack signatures with stale timestamps" do
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "connectors" => { "slack" => true },
        "external_execution_sources" => {}
      })

      stale_timestamp = 10.minutes.ago.to_i.to_s
      stale_signature = "v0=#{OpenSSL::HMAC.hexdigest("SHA256", "signing-secret", "v0:#{stale_timestamp}:#{slack_raw_body}")}"

      expect {
        described_class.call(
          project: project,
          connector_key: "slack",
          event_type: "message_posted",
          payload: slack_payload,
          external_event_id: "slack-stale-timestamp",
          signature: stale_signature,
          secret: "signing-secret",
          raw_body: slack_raw_body,
          request_headers: { "X-Slack-Request-Timestamp" => stale_timestamp }
        )
      }.to raise_error(ArgumentError, /signature verification failed for slack/)
    end

    it "accepts a matching signature from any active secret candidate" do
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "connectors" => { "slack" => true },
        "external_execution_sources" => {}
      })

      event = described_class.call(
        project: project,
        connector_key: "slack",
        event_type: "message_posted",
        payload: slack_payload,
        external_event_id: "slack-rotated-secret",
        signature: slack_signature,
        secrets: [ "new-signing-secret", "signing-secret" ],
        raw_body: slack_raw_body,
        request_headers: { "X-Slack-Request-Timestamp" => slack_timestamp }
      )

      expect(event).to be_persisted
      expect(event.status).to eq("processed")
    end

    it "creates a failed event when connector normalization raises" do
      allow(Interop::Connectors::Jira).to receive(:normalize_event).and_raise(StandardError, "bad payload")

      event = described_class.call(
        project: project,
        connector_key: "jira",
        event_type: "issue_created",
        payload: { "issue" => { "key" => "PROJ-99" } },
        external_event_id: "jira-failed-normalization"
      )

      expect(event.status).to eq("failed")
      expect(event.normalized_data).to eq({ "error" => "bad payload" })
    end
  end
end
