# frozen_string_literal: true

module Prompts
  # Shared language-specific command mappings for test and lint commands.
  # Used by both Prompts::BuildForIssue and Activities::CreateAgentRunActivity.
  module LanguageCommands
    LANGUAGE_TEST_COMMANDS = {
      "ruby" => "bundle exec rspec",
      "javascript" => "npm test",
      "typescript" => "npm test",
      "python" => "pytest",
      "go" => "go test ./...",
      "rust" => "cargo test"
    }.freeze

    LANGUAGE_LINT_COMMANDS = {
      "ruby" => "bundle exec rubocop",
      "javascript" => "npm run lint",
      "typescript" => "npm run lint",
      "python" => "ruff check .",
      "go" => "golangci-lint run",
      "rust" => "cargo clippy"
    }.freeze
  end
end
