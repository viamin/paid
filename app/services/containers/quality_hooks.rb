# frozen_string_literal: true

require "shellwords"

module Containers
  module QualityHooks
    extend ActiveSupport::Concern

    DB_DEPENDENT_TEST_LANGUAGES = %w[ruby].freeze

    def install_quality_hooks(git_ops, agent_run)
      language = detect_language(agent_run.project)
      lint_cmd = Prompts::BuildForIssue::LANGUAGE_LINT_COMMANDS[language]
      test_cmd = Prompts::BuildForIssue::LANGUAGE_TEST_COMMANDS[language]
      mutation_cmd = resolve_mutation_command(agent_run.project, agent_run.settings_user, language)

      # Skip hook installation when no checks exist.
      # When only one or two exist, the others get a no-op fallback (true).
      return unless lint_cmd || test_cmd || mutation_cmd

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
        mutation_cmd = nil
      end

      git_ops.install_git_hooks(
        lint_command: lint_cmd || "true",
        test_command: test_cmd || "true",
        mutation_command: mutation_cmd || "true"
      )
    end

    def detect_language(project)
      lang = project.detected_language if project.respond_to?(:detected_language)
      lang.presence || "ruby"
    end

    def resolve_mutation_command(project, user, language)
      return unless language == "ruby"

      requirement = resolve_mutation_requirement(project, user, language)
      requirement&.command
    end

    def resolve_scheduled_mutation_command(project, user, language)
      requirement = resolve_mutation_requirement(project, user, language)
      return unless requirement

      scheduled_mutation_command(requirement.command)
    end

    private

    def resolve_mutation_requirement(project, user, language)
      return unless language == "ruby"

      PreCommitRequirement
        .resolve(project: project, user: user)
        .find { |record| record.check_type == "mutation_test" }
    end

    def scheduled_mutation_command(command)
      tokens = Shellwords.split(command.to_s)
      return if tokens.empty?

      normalized = []
      jobs_overridden = false
      index = 0

      while index < tokens.length
        token = tokens[index]

        case token
        when "--since"
          index += 2
        when /\A--since=/
          index += 1
        when "--jobs"
          normalized.concat([ "--jobs", "1" ])
          jobs_overridden = true
          index += 2
        when /\A--jobs=/
          normalized.concat([ "--jobs", "1" ])
          jobs_overridden = true
          index += 1
        else
          normalized << token
          index += 1
        end
      end

      normalized.concat([ "--jobs", "1" ]) unless jobs_overridden
      Shellwords.join(normalized)
    end
  end
end
