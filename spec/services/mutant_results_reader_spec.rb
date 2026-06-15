# frozen_string_literal: true

require "rails_helper"

RSpec.describe MutantResultsReader do
  describe ".read" do
    it "returns nil when the results directory is absent" do
      Dir.mktmpdir("mutant-reader") do |worktree_path|
        expect(described_class.read(worktree_path)).to be_nil
      end
    end

    it "returns nil when the results directory is empty" do
      Dir.mktmpdir("mutant-reader") do |worktree_path|
        FileUtils.mkdir_p(File.join(worktree_path, ".mutant/results"))

        expect(described_class.read(worktree_path)).to be_nil
      end
    end

    it "extracts summary counts from the latest results file" do
      worktree_path = Rails.root.join("spec/fixtures/files/mutant/worktree_with_results")

      expect(described_class.read(worktree_path)).to include(
        total_mutations: 20,
        killed_mutations: 19
      )
    end

    it "returns nil when the file lacks required summary fields" do
      Dir.mktmpdir("mutant-reader") do |worktree_path|
        results_dir = File.join(worktree_path, ".mutant/results")
        FileUtils.mkdir_p(results_dir)
        File.write(File.join(results_dir, "run.yml"), "alive_mutations: []\n")

        expect(described_class.read(worktree_path)).to be_nil
      end
    end
  end
end
