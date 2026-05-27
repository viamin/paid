# frozen_string_literal: true

require "rails_helper"

RSpec.describe MutationSweeps::Run do
  describe ".call" do
    let(:project) { create(:project) }
    let(:fixture_worktree) { Rails.root.join("spec/fixtures/files/mutant/worktree_with_results").to_s }
    let(:worktree_service) { instance_double(WorktreeService) }
    let(:container_service) { instance_double(Containers::Provision) }

    before do
      create(:pre_commit_requirement, :mutation_test, project: project, account: project.account, name: "mutant")
      allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
      allow(worktree_service).to receive(:with_temporary_worktree).with(project.default_branch).and_yield(fixture_worktree)
      allow(Containers::Provision).to receive(:with_container).and_yield(container_service)
      allow(container_service).to receive(:execute)
      allow(QualityMetrics::EvaluateGate).to receive(:call)
      allow(QualityAlerts::CheckGate).to receive(:call)
    end

    it "records a scheduled mutation sweep quality metric" do
      metric = described_class.call(project: project, sweep_date: Date.new(2026, 5, 27))

      expect(metric).to be_persisted
      expect(metric.source).to eq("scheduled_mutation_sweep")
      expect(metric.mutation_kill_rate.to_f).to eq(0.95)
      expect(metric.scores).to include("mutation_kill_rate" => 0.95)
      expect(QualityMetrics::EvaluateGate).to have_received(:call).with(quality_metric: metric)
    end
  end
end
