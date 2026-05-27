# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::IngestExternal do
  describe ".call" do
    let(:project) do
      create(:project, interop_settings: {
        "adoption_mode" => "advisory",
        "external_execution_sources" => {
          "cursor" => true
        }
      })
    end

    it "creates an external agent run wired into the project metrics surface" do
      agent_run = described_class.call(
        project: project,
        attributes: {
          external_source_key: "cursor",
          external_run_key: "cursor-123",
          goal: "create_pr",
          status: "completed",
          custom_prompt: "Imported PR automation outcome"
        }
      )

      expect(agent_run).to be_persisted
      expect(agent_run.execution_origin).to eq("external")
      expect(agent_run.external_source_key).to eq("cursor")
      expect(agent_run.adoption_mode_snapshot).to eq("advisory")
    end

    it "rejects ingestion for sources that are not enabled on the project" do
      expect {
        described_class.call(
          project: project,
          attributes: {
            external_source_key: "devin",
            external_run_key: "devin-1",
            custom_prompt: "Imported run"
          }
        )
      }.to raise_error(ArgumentError, /not enabled/)
    end
  end
end
