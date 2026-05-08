# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::PrepareInputs do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let!(:strategy) { create(:orchestration_strategy, :feature_orchestration, account: account, version: 2) }
    let!(:older_version) { create(:orchestration_strategy, :feature_orchestration, account: account, version: 1, active: false) }

    before do
      create(
        :decomposition_decision,
        project: project,
        issue: create(:issue, project: project),
        decision_type: "planning_outcome",
        outcome: "sub_issues_created",
        hints: { "task_count" => 3 },
        metadata: { "policy_source" => "feature_orchestration" }
      )
      create(
        :decomposition_decision,
        project: project,
        issue: create(:issue, project: project),
        decision_type: "parallelization_outcome",
        outcome: "parallelization_failed",
        hints: { "task_count" => 2 },
        error_details: { "type" => "DependencyCycle" },
        metadata: { "policy_source" => "defaults" }
      )
      other_project = create(:project)
      create(:decomposition_decision, project: other_project, issue: create(:issue, project: other_project))
    end

    it "collects policy history and measured coordination outcomes for the account" do
      result = described_class.call(account: account, min_decisions: 2)

      expect(result[:strategy]).to include(id: strategy.id, version: 2, strategy_type: "feature_orchestration")
      expect(result[:prior_versions].map { |row| row[:id] }).to include(strategy.id, older_version.id)
      expect(result.dig(:performance, :decision_count)).to eq(2)
      expect(result.dig(:performance, :success_count)).to eq(1)
      expect(result.dig(:performance, :failure_count)).to eq(1)
      expect(result.dig(:performance, :decision_type_counts)).to include(
        "planning_outcome" => 1,
        "parallelization_outcome" => 1
      )
      expect(result.dig(:performance, :policy_source_counts)).to include(
        "feature_orchestration" => 1,
        "defaults" => 1
      )
      expect(result.dig(:performance, :average_task_count)).to eq(2.5)
      expect(result[:sample_successes].size).to eq(1)
      expect(result[:sample_failures].size).to eq(1)
    end
  end
end
