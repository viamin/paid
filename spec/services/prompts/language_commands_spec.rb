# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::LanguageCommands do
  describe "LANGUAGE_TEST_COMMANDS" do
    it "maps supported languages to test commands" do
      expect(described_class::LANGUAGE_TEST_COMMANDS).to include(
        "ruby" => "bundle exec rspec",
        "python" => "pytest",
        "go" => "go test ./...",
        "rust" => "cargo test",
        "elixir" => "mix test",
        "swift" => "swift test"
      )
    end

    it "maps javascript and typescript to npm test" do
      expect(described_class::LANGUAGE_TEST_COMMANDS["javascript"]).to eq("npm test")
      expect(described_class::LANGUAGE_TEST_COMMANDS["typescript"]).to eq("npm test")
    end

    it "is frozen" do
      expect(described_class::LANGUAGE_TEST_COMMANDS).to be_frozen
    end
  end

  describe "LANGUAGE_LINT_COMMANDS" do
    it "maps supported languages to lint commands" do
      expect(described_class::LANGUAGE_LINT_COMMANDS).to include(
        "ruby" => "bundle exec rubocop",
        "python" => "ruff check .",
        "go" => "golangci-lint run",
        "rust" => "cargo clippy",
        "elixir" => "mix credo --strict",
        "swift" => "swift format lint --recursive ."
      )
    end

    it "maps javascript and typescript to npm run lint" do
      expect(described_class::LANGUAGE_LINT_COMMANDS["javascript"]).to eq("npm run lint")
      expect(described_class::LANGUAGE_LINT_COMMANDS["typescript"]).to eq("npm run lint")
    end

    it "is frozen" do
      expect(described_class::LANGUAGE_LINT_COMMANDS).to be_frozen
    end
  end

  describe ".detected_language" do
    it "returns the project's detected_language when available" do
      project = create(:project)
      project.define_singleton_method(:detected_language) { "python" }

      expect(described_class.detected_language(project)).to eq("python")
    end

    it "defaults to ruby when project does not respond to detected_language" do
      project = create(:project)

      expect(described_class.detected_language(project)).to eq("ruby")
    end

    it "defaults to ruby when detected_language is blank" do
      project = create(:project)
      project.define_singleton_method(:detected_language) { "" }

      expect(described_class.detected_language(project)).to eq("ruby")
    end

    it "defaults to ruby when detected_language is nil" do
      project = create(:project)
      project.define_singleton_method(:detected_language) { nil }

      expect(described_class.detected_language(project)).to eq("ruby")
    end
  end

  describe ".test_languages" do
    it "reads the project's configured test languages" do # @spec POLYGLOT-TEST-003
      project = create(:project, repo_profile: { "test_languages" => %w[elixir javascript] })

      expect(described_class.test_languages(project)).to eq(%w[elixir javascript])
    end

    it "falls back to the detected language" do
      project = create(:project)
      project.define_singleton_method(:detected_language) { "python" }

      expect(described_class.test_languages(project)).to eq(%w[python])
    end
  end

  describe ".test_command" do
    it "joins commands for all configured test languages" do # @spec POLYGLOT-TEST-003
      project = create(:project, repo_profile: { "test_languages" => %w[elixir javascript] })

      expect(described_class.test_command(project)).to eq("mix test && npm test")
    end
  end

  describe ".lint_command" do
    it "joins commands for all configured lint languages" do # @spec POLYGLOT-TEST-003
      project = create(:project, repo_profile: { "test_languages" => %w[ruby typescript] })

      expect(described_class.lint_command(project)).to eq("bundle exec rubocop && npm run lint")
    end
  end

  describe "DEFAULT_LANGUAGE" do
    it "is ruby" do
      expect(described_class::DEFAULT_LANGUAGE).to eq("ruby")
    end
  end
end
