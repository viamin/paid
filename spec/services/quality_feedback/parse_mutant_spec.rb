# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityFeedback::ParseMutant do
  let(:alive_mutation_yaml) do
    <<~YAML
      alive_mutations:
        - subject: Foo#bar
          subject_path: app/models/foo.rb
          source_line: 42
          mutation_diff: return true -> return false
    YAML
  end

  def write_mutant_result(dir, content)
    results_dir = File.join(dir, ".mutant/results")
    FileUtils.mkdir_p(results_dir)
    File.write(File.join(results_dir, "run.yml"), content)
  end

  it "parses alive mutations into a CheckResult" do
    Dir.mktmpdir("mutant-parse") do |dir|
      write_mutant_result(dir, alive_mutation_yaml)

      result = described_class.call(worktree_path: dir)

      expect(result).to be_a(QualityFeedbackService::CheckResult)
      expect(result).not_to be_success
      expect(result.errors).to contain_exactly(
        hash_including(
          file: "app/models/foo.rb",
          line: 42,
          rule: "alive_mutation",
          severity: "high"
        )
      )
    end
  end

  it "returns a passing empty result when no mutant files exist" do
    Dir.mktmpdir("mutant-empty") do |dir|
      result = described_class.call(worktree_path: dir)

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(result.warnings).to be_empty
    end
  end
end
