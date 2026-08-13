# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Connectors::Jira do
  it "exposes key and display_name" do
    expect(described_class.key).to eq("jira")
    expect(described_class.display_name).to eq("Jira")
  end

  it "declares event types" do
    expect(described_class.event_types).to include("issue_created", "issue_updated")
  end

  it "normalizes a Jira issue event" do
    payload = {
      "issue" => {
        "key" => "PROJ-123",
        "fields" => {
          "summary" => "Fix login bug",
          "status" => { "name" => "In Progress" },
          "priority" => { "name" => "High" },
          "labels" => [ "bug" ]
        }
      }
    }
    result = described_class.normalize_event(payload)
    expect(result["external_id"]).to eq("PROJ-123")
    expect(result["title"]).to eq("Fix login bug")
    expect(result["status"]).to eq("In Progress")
  end
end
