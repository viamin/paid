# frozen_string_literal: true

module Containers
  module QualityHooks
    extend ActiveSupport::Concern

    included do
      DB_DEPENDENT_TEST_LANGUAGES = %w[ruby].freeze
    end

    def install_quality_hooks(git_ops, agent_run)
      language = detect_language(agent_run.project)
      lint_cmd = Prompts::BuildForIssue::LANGUAGE_LINT_COMMANDS[language]
      test_cmd = Prompts::BuildForIssue::LANGUAGE_TEST_COMMANDS[language]

      # Skip hook installation when neither lint nor test commands exist.
      # When only one exists, the other gets a no-op fallback (true).
      return unless lint_cmd || test_cmd

      # Convert the test hook to a no-op for DB-dependent languages when no
      # database container is running. Rails test suites (rspec) fail
      # unconditionally without a database, trapping the agent in a commit
      # loop it cannot escape (hooks reject the commit, the agent can't skip
      # hooks, and retries until timeout). Non-DB languages (JS, Go, Rust)
      # keep their test hooks since their suites typically run without postgres.
      # The prompt already tells the agent to run tests manually and report
      # which tests couldn't execute due to missing services.
      if DB_DEPENDENT_TEST_LANGUAGES.include?(language) && !agent_run.project.has_running_database_container?
        test_cmd = nil
      end

      git_ops.install_git_hooks(
        lint_command: lint_cmd || "true",
        test_command: test_cmd || "true"
      )
    end

    def detect_language(project)
      lang = project.detected_language if project.respond_to?(:detected_language)
      lang.presence || "ruby"
    end
  end
end
