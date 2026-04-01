# frozen_string_literal: true

module PreCommitRequirements
  # Evaluates pre-commit requirements for an agent run by executing configured
  # checks and collecting results. Supports auto-fix mode where a failing check
  # can be retried after running its fix command.
  #
  # @example
  #   result = PreCommitRequirements::Evaluate.call(agent_run: agent_run)
  #   result[:passed]     # => true/false
  #   result[:results]    # => [{ requirement: ..., passed: true/false, output: "..." }, ...]
  #   result[:blocking]   # => true if any blocking check failed
  class Evaluate
    MAX_AUTO_FIX_ATTEMPTS = 3

    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      requirements = PreCommitRequirement.resolve(
        project: agent_run.project,
        user: agent_run.project.effective_owner
      )

      return { passed: true, results: [], blocking: false } if requirements.empty?

      results = requirements.map { |req| evaluate_requirement(req) }
      blocking = results.any? { |r| r[:blocking] && !r[:passed] }

      {
        passed: results.all? { |r| r[:passed] || !r[:blocking] },
        results: results,
        blocking: blocking
      }
    end

    private

    def evaluate_requirement(requirement)
      result = run_check(requirement)

      if !result[:passed] && requirement.auto_fix? && requirement.fix_command.present?
        result = attempt_auto_fix(requirement)
      end

      log_result(requirement, result)

      {
        requirement_id: requirement.id,
        name: requirement.name,
        check_type: requirement.check_type,
        passed: result[:passed],
        output: result[:output],
        blocking: requirement.blocking?,
        failure_behavior: requirement.failure_behavior,
        auto_fixed: result[:auto_fixed] || false
      }
    end

    def run_check(requirement)
      return { passed: false, output: "No container available" } unless agent_run.container_id.present?

      result = agent_run.execute_in_container(requirement.command)
      passed = container_result_success?(result)
      output = container_result_output(result)

      { passed: passed, output: output.to_s.truncate(10_000) }
    rescue Containers::Provision::Error => e
      { passed: false, output: e.message.to_s.truncate(10_000) }
    end

    def attempt_auto_fix(requirement)
      unless agent_run.container_id.present?
        return { passed: false, output: "No container available for auto-fix", auto_fixed: false }
      end

      MAX_AUTO_FIX_ATTEMPTS.times do |attempt|
        fix_result = agent_run.execute_in_container(requirement.fix_command)

        unless container_result_success?(fix_result)
          fix_output = container_result_output(fix_result).to_s.truncate(10_000)
          return { passed: false, output: "Auto-fix failed: #{fix_output}".truncate(10_000), auto_fixed: false }
        end

        result = run_check(requirement)
        if result[:passed]
          return result.merge(auto_fixed: true)
        end

        log_auto_fix_attempt(requirement, attempt + 1, result)
      rescue Containers::Provision::Error => e
        return { passed: false, output: "Auto-fix failed: #{e.message}".truncate(10_000), auto_fixed: false }
      end

      { passed: false, output: "Auto-fix exhausted after #{MAX_AUTO_FIX_ATTEMPTS} attempts", auto_fixed: false }
    end

    def container_result_success?(result)
      result.success?
    end

    def container_result_output(result)
      stdout = result[:stdout].to_s
      stderr = result[:stderr].to_s

      combined = [ stdout, stderr ].reject(&:blank?).join("\n")
      return combined if combined.present?

      exit_code = result[:exit_code]
      exit_code ? "Command exited with code #{exit_code}" : ""
    end

    def log_result(requirement, result)
      status = result[:passed] ? "passed" : "failed"
      agent_run.log!(
        "system",
        "Pre-commit check '#{requirement.name}' #{status}",
        metadata: {
          event: "pre_commit_check",
          requirement_id: requirement.id,
          check_type: requirement.check_type,
          passed: result[:passed],
          auto_fixed: result[:auto_fixed] || false,
          output_preview: result[:output].to_s.truncate(500)
        }
      )
    end

    def log_auto_fix_attempt(requirement, attempt, result)
      agent_run.log!(
        "system",
        "Auto-fix attempt #{attempt}/#{MAX_AUTO_FIX_ATTEMPTS} for '#{requirement.name}' did not resolve the issue",
        metadata: {
          event: "pre_commit_check",
          requirement_id: requirement.id,
          attempt: attempt,
          output_preview: result[:output].to_s.truncate(500)
        }
      )
    end
  end
end
