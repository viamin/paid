# frozen_string_literal: true

require "shellwords"

module Containers
  module QualityHooks
    extend ActiveSupport::Concern

    DB_DEPENDENT_TEST_LANGUAGES = %w[ruby elixir].freeze

    def install_quality_hooks(git_ops, agent_run) # @spec QUALITY-LOOPS-004
      languages = command_languages(agent_run.project)
      lint_cmd = join_commands(languages.filter_map { |language| Prompts::BuildForIssue::LANGUAGE_LINT_COMMANDS[language] })
      test_languages = runnable_test_languages(agent_run.project, languages)
      test_cmd = join_commands(test_languages.filter_map { |language| Prompts::BuildForIssue::LANGUAGE_TEST_COMMANDS[language] })
      mutation_cmd = resolve_mutation_command(agent_run.project, agent_run.settings_user, test_languages)

      # Skip hook installation when no checks exist.
      # When only one or two exist, the others get a no-op fallback (true).
      return unless lint_cmd || test_cmd || mutation_cmd

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

    def resolve_mutation_command(project, user, languages) # @spec QUALITY-LOOPS-003
      return unless Array(languages).include?("ruby")

      requirement = resolve_mutation_requirement(project, user, "ruby")
      return unless requirement

      MutantResultsReader.with_results_dir(requirement.command)
    end

    def resolve_scheduled_mutation_command(project, user, language)
      requirement = resolve_mutation_requirement(project, user, language)
      return unless requirement

      scheduled_mutation_command(requirement.command)
    end

    private

    def command_languages(project)
      Prompts::LanguageCommands.test_languages(project)
    end

    def runnable_test_languages(project, languages)
      return languages if project.has_running_database_container?

      Array(languages).reject { |language| DB_DEPENDENT_TEST_LANGUAGES.include?(language) }
    end

    def join_commands(commands)
      commands.uniq.presence&.join(" && ")
    end

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
        when "--results-dir"
          index += 2
        when /\A--results-dir=/
          index += 1
        else
          normalized << token
          index += 1
        end
      end

      normalized.concat([ "--jobs", "1" ]) unless jobs_overridden
      normalized.concat([ "--results-dir", MutantResultsReader::RESULTS_DIRECTORY ])
      Shellwords.join(normalized)
    end
  end
end
