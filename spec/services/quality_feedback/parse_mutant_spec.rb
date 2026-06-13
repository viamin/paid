# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityFeedback::ParseMutant do
  def fixture_worktree(name)
    Rails.root.join("spec/fixtures/files/mutant/#{name}").to_s
  end

  it "returns a passing result when alive_mutations is empty" do
    result = described_class.call(worktree_path: fixture_worktree("worktree_zero_alive"))

    expect(result).to be_a(QualityFeedbackService::CheckResult)
    expect(result).to be_success
    expect(result.errors).to be_empty
    expect(result.warnings).to be_empty
  end

  it "parses several alive mutations into errors" do
    result = described_class.call(worktree_path: fixture_worktree("worktree_several_alive"))

    expect(result).not_to be_success
    expect(result.errors).to contain_exactly(
      hash_including(file: "app/models/foo.rb", line: 42, rule: "alive_mutation", severity: "high"),
      hash_including(file: "app/services/baz.rb", line: 17, rule: "alive_mutation", severity: "high"),
      hash_including(file: "app/models/widget.rb", line: 8, rule: "alive_mutation", severity: "high")
    )
  end

  it "parses alive mutations and ignores errored mutations" do
    result = described_class.call(worktree_path: fixture_worktree("worktree_with_errored"))

    expect(result).not_to be_success
    expect(result.errors).to contain_exactly(
      hash_including(file: "app/models/foo.rb", line: 42, rule: "alive_mutation", severity: "high")
    )
  end

  it "includes the mutation diff in the error message" do
    result = described_class.call(worktree_path: fixture_worktree("worktree_several_alive"))

    message = result.errors.first[:message]
    expect(message).to include("Foo#bar")
    expect(message).to include("return true -> return false")
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
