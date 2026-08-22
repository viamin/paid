# frozen_string_literal: true

require "shellwords"

module Containers
  module QualityHooks
    extend ActiveSupport::Concern

    # Languages whose test suites require a running database service container.
    # Ruby (Rails/ActiveRecord) and Elixir (Phoenix/Ecto) both fail
    # unconditionally without PostgreSQL, which would trap the agent in a
    # commit loop. Their test hooks are no-op'd when no DB container is running.
    DB_DEPENDENT_TEST_LANGUAGES = %w[ruby elixir].freeze

    def install_quality_hooks(git_ops, agent_run) # @spec QUALITY-LOOPS-004 # @spec POLYGLOT-TEST-003
      languages = Prompts::LanguageCommands.test_languages(agent_run.project)
      db_available = agent_run.project.has_running_database_container?

      lint_commands, test_commands = resolve_commands(languages, db_available)
      mutation_cmd = resolve_mutation_command(agent_run.project, agent_run.settings_user, languages)
      mutation_cmd = nil if ruby_db_gated?(languages, db_available)
      # RDR-056 (Strict TDD): mutation checks run after green, not during the
      # red test-review phase — a test_writing run has no implementation to
      # mutate yet, and running mutant against approved tests here would only
      # produce noise before a human/agent has reviewed the tests themselves.
      mutation_cmd = nil if agent_run.tdd_test_writing_phase?

      return unless lint_commands.any? || test_commands.any? || mutation_cmd
      install_args = {
        lint_command: lint_commands,
        test_command: test_commands,
        mutation_command: mutation_cmd || "true"
      }
      pre_commit_guard = tdd_write_guard_script(agent_run)
      install_args[:pre_commit_guard] = pre_commit_guard if pre_commit_guard.present?

      git_ops.install_git_hooks(**install_args)
    end

    def resolve_mutation_command(project, user, languages) # @spec QUALITY-LOOPS-003
      return unless Array(languages).include?("ruby")

      requirement = resolve_mutation_requirement(project, user)
      return unless requirement

      MutantResultsReader.with_results_dir(requirement.command)
    end

    def resolve_scheduled_mutation_command(project, user, languages)
      return unless Array(languages).include?("ruby")

      requirement = resolve_mutation_requirement(project, user)
      return unless requirement

      scheduled_mutation_command(requirement.command)
    end

    private

    # Resolves per-language lint and test commands for a polyglot language set.
    # Lint always runs; test commands for DB-dependent languages are dropped
    # when no database container is available so commits are not trapped behind
    # infrastructure-dependent failures.
    def resolve_commands(languages, db_available)
      lint_commands = []
      test_commands = []

      languages.each do |language|
        lint_commands << Prompts::LanguageCommands::LANGUAGE_LINT_COMMANDS[language]
        next if db_dependent_test_language?(language) && !db_available

        test_commands << Prompts::LanguageCommands::LANGUAGE_TEST_COMMANDS[language]
      end

      [ lint_commands.compact, test_commands.compact ]
    end

    def db_dependent_test_language?(language)
      DB_DEPENDENT_TEST_LANGUAGES.include?(language)
    end

    # Mutation testing is Ruby-only and DB-dependent; skip it when Ruby's test
    # hook is itself gated out by a missing database container.
    def ruby_db_gated?(languages, db_available)
      languages.include?("ruby") && db_dependent_test_language?("ruby") && !db_available
    end

    def resolve_mutation_requirement(project, user)
      PreCommitRequirement
        .resolve(project: project, user: user)
        .find { |record| record.check_type == "mutation_test" }
    end

    def scheduled_mutation_command(command)
      tokens = Shellwords.split(command.to_s)
      return if tokens.empty?

      env_tokens, command_tokens = MutantResultsReader.send(:split_env_prefix, tokens)
      normalized = []
      jobs_overridden = false
      index = 0

      while index < command_tokens.length
        token = command_tokens[index]

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
      MutantResultsReader.with_results_dir(Shellwords.join(env_tokens + normalized))
    end

    def tdd_write_guard_script(agent_run)
      return unless agent_run.tdd_governed?

      <<~SHELL
        # Enforce the run-scoped TDD write boundary before the commit lands.
        tdd_phase="#{agent_run.tdd_phase}"
        tdd_return_to_review_marker="#{Tdd::ReturnToTestReview::HOOK_MARKER_RELATIVE_PATH}"
        tdd_changed_files="$(git diff --cached --name-only --diff-filter=ACMR)"

        if [ -n "$tdd_changed_files" ]; then
          tdd_violation=0
          tdd_forbidden_files=""
          tdd_old_ifs="$IFS"
          IFS='
        '
          for tdd_file in $tdd_changed_files; do
            [ -n "$tdd_file" ] || continue

            case "$tdd_phase" in
              test_writing)
                case "$tdd_file" in
                  #{allowed_test_writing_patterns})
                    ;;
                  *)
                    tdd_violation=1
                    tdd_forbidden_files="${tdd_forbidden_files}${tdd_file}\n"
                    ;;
                esac
                ;;
              test_fixing)
                if [ ! -f "$tdd_return_to_review_marker" ]; then
                  case "$tdd_file" in
                    #{test_file_patterns})
                      tdd_violation=1
                      tdd_forbidden_files="${tdd_forbidden_files}${tdd_file}\n"
                      ;;
                  esac
                fi
                ;;
              refactor)
                case "$tdd_file" in
                  #{test_file_patterns})
                    tdd_violation=1
                    tdd_forbidden_files="${tdd_forbidden_files}${tdd_file}\n"
                    ;;
                esac
                ;;
            esac
          done
          IFS="$tdd_old_ifs"

          if [ "$tdd_violation" -ne 0 ]; then
            echo "TDD write guard violation (${tdd_phase}). Forbidden staged files:" >&2
            printf '%b' "$tdd_forbidden_files" >&2
            exit 1
          fi
        fi
      SHELL
    end

    def test_file_patterns
      @test_file_patterns ||= Tdd::WriteGuard::TEST_PATH_PREFIXES.map { |prefix| "#{prefix}*" }.join("|")
    end

    def allowed_test_writing_patterns
      @allowed_test_writing_patterns ||= shell_patterns(
        prefixes: Tdd::WriteGuard::TEST_PATH_PREFIXES + Tdd::WriteGuard::LID_DOC_PREFIXES,
        exact_paths: Tdd::WriteGuard::LID_DOC_EXACT_PATHS
      )
    end

    def shell_patterns(prefixes:, exact_paths: [])
      Array(prefixes).map { |prefix| "#{prefix}*" }
        .concat(Array(exact_paths))
        .join("|")
    end
  end
end
