# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-003
RSpec.describe Knowledge::Collectors::SessionSummaryCollector do
  subject(:collector) do
    described_class.new(project:, project_version:, collector_run:, options: {})
  end

  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project:) }
  let(:collector_run) { create(:collector_run, project_version:, collector_type: "session_summary") }
  let(:agent_run) { create(:agent_run, :completed, project: project) }
  let(:record) do
    create(:agent_run_session_summary, project:, agent_run:,
      summary: "Implemented rate limiting.",
      files_touched: [ "app/services/rate_limiter.rb" ],
      decisions: [ "Used a sliding window." ],
      assumptions: [],
      failures: [],
      follow_ups: [],
      learnings: [ "Config lives in config/rate_limits.yml." ])
  end

  describe "#collect" do
    it "returns an artifact for every session summary in the project" do
      record
      artifacts = collector.collect

      expect(artifacts.size).to eq(1)
      expect(artifacts.first[:artifact_type]).to eq("session_summary")
    end
  end

  describe "#artifact_for" do
    it "builds a scoped, identified artifact hash" do
      artifact = collector.artifact_for(record)

      expect(artifact[:artifact_type]).to eq("session_summary")
      expect(artifact[:scope_path]).to eq("agent_runs/#{agent_run.id}/session_summary")
      expect(artifact[:identifier]).to eq("Agent run ##{agent_run.id}")
      expect(artifact[:metadata]).to include(
        agent_run_session_summary_id: record.id,
        agent_run_id: agent_run.id,
        status: "observation"
      )
    end

    it "renders content with the summary and populated sections" do
      artifact = collector.artifact_for(record)

      expect(artifact[:content]).to include("Implemented rate limiting.")
      expect(artifact[:content]).to include("## Files Touched")
      expect(artifact[:content]).to include("- app/services/rate_limiter.rb")
      expect(artifact[:content]).not_to include("## Assumptions")
    end

    it "builds a summary chunk plus evidence chunks for decisions and learnings" do
      artifact = collector.artifact_for(record)

      chunk_types = artifact[:chunks].map { |c| c[:chunk_type] }
      expect(chunk_types).to eq(%w[summary evidence evidence])
    end
  end
end
