# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::LanguageCommands do # @spec POLYGLOT-TEST-003
  describe "LANGUAGE_TEST_COMMANDS" do
    it "maps supported languages to test commands" do
      expect(described_class::LANGUAGE_TEST_COMMANDS).to include(
        "ruby" => "bundle exec rspec",
        "python" => "pytest",
        "go" => "go test ./...",
        "rust" => "cargo test"
      )
    end

    it "maps javascript and typescript to npm test" do
      expect(described_class::LANGUAGE_TEST_COMMANDS["javascript"]).to eq("npm test")
      expect(described_class::LANGUAGE_TEST_COMMANDS["typescript"]).to eq("npm test")
    end

    it "maps elixir and swift" do
      expect(described_class::LANGUAGE_TEST_COMMANDS["elixir"]).to eq("mix test")
      expect(described_class::LANGUAGE_TEST_COMMANDS["swift"]).to eq("swift test")
    end

    it "covers the full RDR-046 target language matrix" do
      expect(described_class::LANGUAGE_TEST_COMMANDS.keys).to contain_exactly(
        "ruby", "javascript", "typescript", "python", "go", "rust", "elixir", "swift"
      )
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
        "rust" => "cargo clippy"
      )
    end

    it "maps javascript and typescript to npm run lint" do
      expect(described_class::LANGUAGE_LINT_COMMANDS["javascript"]).to eq("npm run lint")
      expect(described_class::LANGUAGE_LINT_COMMANDS["typescript"]).to eq("npm run lint")
    end

    it "maps elixir and swift" do
      expect(described_class::LANGUAGE_LINT_COMMANDS["elixir"]).to eq("mix credo --strict")
      expect(described_class::LANGUAGE_LINT_COMMANDS["swift"]).to eq("swift format lint --recursive .")
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
    it "falls back to the detected primary language when no profile is set" do
      project = create(:project)
      project.define_singleton_method(:detected_language) { "go" }

      expect(described_class.test_languages(project)).to eq([ "go" ])
    end

    it "reads the test_languages array from the persisted profile" do
      project = create(:project, repo_profile: { "test_languages" => [ "ruby", "elixir" ] })

      expect(described_class.test_languages(project)).to eq([ "ruby", "elixir" ])
    end

    it "falls back to the profile languages list when test_languages is absent" do
      project = create(:project, repo_profile: { "languages" => [ "elixir", "javascript" ] })

      expect(described_class.test_languages(project)).to eq([ "elixir", "javascript" ])
    end

    it "normalizes language keys to downcased strings" do
      project = create(:project, repo_profile: { "test_languages" => [ "Ruby", "ELIXIR" ] })

      expect(described_class.test_languages(project)).to eq([ "ruby", "elixir" ])
    end
  end

  describe ".test_commands_for and .lint_commands_for" do
    it "resolves a single command for a single-language project" do
      project = create(:project)
      project.define_singleton_method(:detected_language) { "python" }

      expect(described_class.test_commands_for(project)).to eq([ "pytest" ])
      expect(described_class.lint_commands_for(project)).to eq([ "ruff check ." ])
    end

    it "resolves one command per language for a polyglot project" do
      project = create(:project, repo_profile: { "test_languages" => [ "ruby", "elixir", "go" ] })

      expect(described_class.test_commands_for(project)).to eq(
        [ "bundle exec rspec", "mix test", "go test ./..." ]
      )
      expect(described_class.lint_commands_for(project)).to eq(
        [ "bundle exec rubocop", "mix credo --strict", "golangci-lint run" ]
      )
    end

    it "drops languages that have no command mapping" do
      project = create(:project, repo_profile: { "test_languages" => [ "ruby", "cobol" ] })

      expect(described_class.test_commands_for(project)).to eq([ "bundle exec rspec" ])
    end

    it "returns a fallback when no language resolves to a command" do
      project = create(:project, repo_profile: { "test_languages" => [ "cobol" ] })

      expect(described_class.test_commands_for(project)).to eq([ 'echo "No test command configured"' ])
      expect(described_class.lint_commands_for(project)).to eq([ 'echo "No lint command configured"' ])
    end
  end

  describe ".format_for_prompt" do
    it "renders a single command unchanged" do
      expect(described_class.format_for_prompt("bundle exec rspec")).to eq("bundle exec rspec")
    end

    it "joins a polyglot command set with a sequential separator" do
      expect(described_class.format_for_prompt([ "bundle exec rspec", "mix test" ])).to eq(
        "bundle exec rspec, then mix test"
      )
    end
  end

  describe "DEFAULT_LANGUAGE" do
    it "is ruby" do
      expect(described_class::DEFAULT_LANGUAGE).to eq("ruby")
    end
  end
end
