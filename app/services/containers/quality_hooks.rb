# frozen_string_literal: true

require "set"

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

      requirement = PreCommitRequirement
        .resolve(project: project, user: user)
        .find { |record| record.check_type == "mutation_test" }
      return unless requirement

      warn_once_when_mutant_license_missing(project, requirement.command)
      requirement.command
    end

    def warn_once_when_mutant_license_missing(project, command)
      return unless command.to_s.include?("--usage commercial")
      return if forwarded_mutant_license_key_present?

      warned_projects = self.class.instance_variable_get(:@mutant_license_warned_projects)
      warned_projects ||= self.class.instance_variable_set(:@mutant_license_warned_projects, Set.new)
      return if warned_projects.include?(project.id)

      warned_projects << project.id

      Rails.logger.warn(
        message: "quality_hooks.mutant_license_missing",
        project_id: project.id,
        project: project.full_name
      )
    end

    def forwarded_mutant_license_key_present?
      ENV["MUTANT_LICENSE_KEY"].present?
    end
  end
end
