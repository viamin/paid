# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# @spec PROJECT-READINESS-001, PROJECT-READINESS-002, PROJECT-READINESS-003, PROJECT-READINESS-004, POLYGLOT-TEST-003
RSpec.describe Projects::Readiness do
  def evaluate(tdd_mode:, language:, repo_profile: {}, fixture: nil, files: [], directories: [])
    project = build(:project, tdd_mode:, primary_language: language, repo_profile:)

    if fixture
      described_class.call(project:, repo_path: fixture)
    else
      Dir.mktmpdir do |repo_path|
        directories.each { |directory| FileUtils.mkdir_p(File.join(repo_path, directory)) }
        files.each do |file|
          path = File.join(repo_path, file)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "fixture\n")
        end
        return described_class.call(project:, repo_path:)
      end
    end
  end

  def forager_ios_fixture
    Rails.root.join("spec/fixtures/projects/forager-ios")
  end

  describe ".call" do
    it "reports every strict-TDD prerequisite absent from the current Forager-iOS fixture" do
      result = evaluate(tdd_mode: "strict", language: "GDScript", fixture: forager_ios_fixture)

      expect(result.gaps.map(&:kind)).to contain_exactly(
        "missing_ci",
        "missing_test_directory",
        "missing_test_command"
      )
      expect(result.gaps.find { |gap| gap.kind == "missing_test_directory" }.evidence).to include(
        ecosystem: "godot", checked_paths: %w[test tests]
      )
      expect(result.evaluated_at).to be_a(ActiveSupport::TimeWithZone)
      expect(result.to_h).to include(evaluated_at: result.evaluated_at.iso8601)
    end

    it "returns no gaps when a strict Ruby project has CI and a test directory" do
      result = evaluate(
        tdd_mode: "strict",
        language: "Ruby",
        directories: [ ".github/workflows", "spec" ],
        files: [ ".github/workflows/test.yml" ]
      )

      expect(result).to be_satisfied
      expect(result.gaps).to be_empty
    end

    it "applies the same structural TDD prerequisites in non-strict mode" do
      result = evaluate(tdd_mode: "non_strict", language: "Python")

      expect(result.gaps.map(&:kind)).to contain_exactly("missing_ci", "missing_test_directory")
      expect(result.gaps.find { |gap| gap.kind == "missing_test_directory" }.evidence).to include(
        ecosystem: "python", checked_paths: %w[tests test]
      )
    end

    it "recognizes a non-strict Python project with all prerequisites" do
      result = evaluate(
        tdd_mode: "non_strict",
        language: "Python",
        directories: [ ".github/workflows", "tests" ],
        files: [ ".github/workflows/test.yml" ]
      )

      expect(result).to be_satisfied
    end

    it "uses configured test languages when checking test directories" do
      result = evaluate(
        tdd_mode: "strict",
        language: "Ruby",
        repo_profile: { "test_languages" => [ "python" ] },
        directories: [ ".github/workflows", "tests" ],
        files: [ ".github/workflows/test.yml" ]
      )

      expect(result).to be_satisfied
    end

    it "adds no TDD gaps when TDD mode is off" do
      result = evaluate(tdd_mode: "off", language: "GDScript", fixture: forager_ios_fixture)

      expect(result).to be_satisfied
    end
  end
end
