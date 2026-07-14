# frozen_string_literal: true

require "rails_helper"

RSpec.describe MutantResultsReader do
  describe ".with_results_dir" do
    it "appends --results-dir when absent" do
      result = described_class.with_results_dir("bundle exec mutant run --use rspec")

      expect(result).to eq("bundle exec mutant run --use rspec --results-dir .mutant/results")
    end

    it "strips existing space-separated --results-dir and replaces with canonical path" do
      result = described_class.with_results_dir("bundle exec mutant run --results-dir /custom/path --use rspec")

      expect(result).to eq("bundle exec mutant run --use rspec --results-dir .mutant/results")
    end

    it "strips existing equals-separated --results-dir and replaces with canonical path" do
      result = described_class.with_results_dir("bundle exec mutant run --results-dir=/custom/path --use rspec")

      expect(result).to eq("bundle exec mutant run --use rspec --results-dir .mutant/results")
    end

    it "strips dangling --results-dir at end of command and replaces with canonical path" do
      result = described_class.with_results_dir("bundle exec mutant run --use rspec --results-dir")

      expect(result).to eq("bundle exec mutant run --use rspec --results-dir .mutant/results")
    end

    it "returns blank string unchanged" do
      expect(described_class.with_results_dir("")).to eq("")
    end

    it "returns nil unchanged" do
      expect(described_class.with_results_dir(nil)).to be_nil
    end
  end

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

    it "extracts counts from the latest results file using the 'killed' key" do
      worktree_path = Rails.root.join("spec/fixtures/files/mutant/worktree_with_results")

      expect(described_class.read(worktree_path)).to include(
        total_mutations: 20,
        killed_mutations: 19
      )
    end

    it "falls back to 'killed_mutations' when 'killed' is absent" do
      Dir.mktmpdir("mutant-reader") do |worktree_path|
        results_dir = File.join(worktree_path, ".mutant/results")
        FileUtils.mkdir_p(results_dir)
        File.write(File.join(results_dir, "run.yml"), <<~YAML)
          total_mutations: 10
          killed_mutations: 8
        YAML

        expect(described_class.read(worktree_path)).to include(
          total_mutations: 10,
          killed_mutations: 8
        )
      end
    end

    it "returns nil when the file lacks required fields" do
      Dir.mktmpdir("mutant-reader") do |worktree_path|
        results_dir = File.join(worktree_path, ".mutant/results")
        FileUtils.mkdir_p(results_dir)
        File.write(File.join(results_dir, "run.yml"), "alive_mutations: []\n")

        expect(described_class.read(worktree_path)).to be_nil
      end
    end
  end
end
