# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectMutationScore do
  describe ".call" do
    it "returns nil when mutant results are absent" do
      Dir.mktmpdir("mutation-score") do |worktree_path|
        agent_run = build(:agent_run, worktree_path: worktree_path)

        expect(described_class.call(agent_run: agent_run)).to be_nil
      end
    end

    it "returns nil when the results directory is empty" do
      Dir.mktmpdir("mutation-score") do |worktree_path|
        FileUtils.mkdir_p(File.join(worktree_path, ".mutant/results"))
        agent_run = build(:agent_run, worktree_path: worktree_path)

        expect(described_class.call(agent_run: agent_run)).to be_nil
      end
    end

    it "returns the kill ratio from a fixture results file" do
      agent_run = build(
        :agent_run,
        worktree_path: Rails.root.join("spec/fixtures/files/mutant/worktree_with_results").to_s
      )

      expect(described_class.call(agent_run: agent_run)).to eq(0.95)
    end

    it "returns nil when the mutant run reported zero total mutations" do
      agent_run = build(:agent_run, worktree_path: "/tmp/unused")
      allow(MutantResultsReader).to receive(:read).with(agent_run.worktree_path).and_return(
        total_mutations: 0,
        killed_mutations: 0
      )

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end
  end
end
