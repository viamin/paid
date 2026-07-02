# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunResourceProfiles::Resolve do
  describe ".call" do
    let(:project) { create(:project) }

    it "falls back from a sparse specific profile to the runner+goal profile" do
      create(:agent_run_resource_profile,
        account: project.account,
        project: project,
        sample_count: 1,
        recommended_memory_limit_bytes: 1.gigabyte)
      create(:agent_run_resource_profile, :runner_goal,
        runner_key: "claude",
        goal: "create_pr",
        sample_count: 4,
        recommended_memory_limit_bytes: 2.gigabytes)
      create(:agent_run_resource_profile, :project_level,
        account: project.account,
        project: project,
        sample_count: 5,
        recommended_memory_limit_bytes: 3.gigabytes)

      result = described_class.call(project: project, runner_key: "claude", goal: "create_pr")

      expect(result[:source]).to eq("runner_goal")
      expect(result[:recommended_memory_limit_bytes]).to eq(2.gigabytes)
    end

    it "falls back to project, then account, then global when narrower scopes are absent or sparse" do
      create(:agent_run_resource_profile, :project_level,
        account: project.account,
        project: project,
        sample_count: 2,
        recommended_memory_limit_bytes: 2.gigabytes)
      create(:agent_run_resource_profile, :account_level,
        account: project.account,
        sample_count: 4,
        recommended_memory_limit_bytes: 3.gigabytes)
      create(:agent_run_resource_profile, :global,
        sample_count: 5,
        recommended_memory_limit_bytes: 4.gigabytes)

      result = described_class.call(project: project, runner_key: "claude", goal: "create_pr")

      expect(result[:source]).to eq("account")
      expect(result[:recommended_memory_limit_bytes]).to eq(3.gigabytes)
    end

    it "returns the default estimate when no sufficient profile exists" do
      result = described_class.call(project: project, runner_key: "claude", goal: "create_pr")

      expect(result[:source]).to eq("default")
      expect(result[:profile]).to be_nil
      expect(result[:recommended_memory_limit_bytes]).to eq(
        AgentRunResourceProfile::DEFAULT_ESTIMATE_MEMORY_LIMIT_BYTES
      )
    end
  end
end
