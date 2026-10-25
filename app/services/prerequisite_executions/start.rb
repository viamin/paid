# frozen_string_literal: true

module PrerequisiteExecutions
  # Bounded prepare/start (and idempotent resume/retry entry) for a
  # prerequisite evidence validation.
  #
  # Capability-aware: capabilities are inspected through the provisioner's
  # placement interfaces before anything provisions. A missing host
  # capability or authorization records an +unavailable+ attempt with the
  # exact authorized setup action instead of running a partial contract or
  # silently enabling a flag.
  #
  # @spec PREREQ-EXEC-005 @spec PREREQ-EXEC-006 @spec PREREQ-EXEC-014
  class Start
    Result = Data.define(:validation, :outcome, :message) do
      def started?
        outcome == :started
      end

      def unavailable?
        outcome == :unavailable
      end
    end

    MAX_NATIVE_COMMAND_LENGTH = 2000
    VALID_BRANCH_FORMAT = /\A[A-Za-z0-9._\/-]+\z/

    InvalidError = Class.new(ArgumentError)

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, actor:, branch:, native_command:, marketplace_entry_id: nil,
      enqueuer: ->(validation) { PrerequisiteExecutions::ValidationJob.perform_later(validation.id) })
      @project = project
      @issue = issue
      @actor = actor
      @branch = branch.to_s.strip
      @native_command = native_command.to_s.strip
      @marketplace_entry_id = marketplace_entry_id
      @enqueuer = enqueuer
    end

    def call
      validate_inputs!
      return Result.new(active_attempt, :existing_active,
        "A validation attempt is already active for ##{issue.github_number}.") if active_attempt

      return Result.new(latest_attempt, :existing_succeeded,
        "Evidence for this scope was already collected; review the recorded attempt.") if existing_succeeded?

      capabilities = capabilities_report

      # An unchanged unavailable attempt is refreshed in place (fresh
      # snapshot and actions) rather than retried — no authorization or
      # scope changed, so a retry would fail the same way. When the
      # refreshed inspection now reports ready (e.g. host readiness
      # recovered — environment state is not part of the scope digest), the
      # placeholder is replaced by a real attempt.
      if unchanged_unavailable_attempt?(capabilities)
        return Result.new(latest_attempt, :unavailable, unavailable_message) unless capabilities.ready?

        latest_attempt.destroy!
      end

      validation = if capabilities.ready?
        start_attempt!(capabilities)
      else
        record_unavailable_attempt!(capabilities)
      end

      Result.new(validation, validation.unavailable? ? :unavailable : :started,
        validation.unavailable? ? unavailable_message : "Validation started for ##{issue.github_number}.")
    end

    private

    attr_reader :project, :issue, :actor, :branch, :native_command, :marketplace_entry_id, :enqueuer

    def validate_inputs!
      raise InvalidError, "Select an open issue of this project." unless issue && issue.project_id == project.id
      raise InvalidError, "##{issue.github_number} is not an open issue." unless issue.github_state == "open" && !issue.is_pull_request?
      raise InvalidError, "Provide the native analyzer command to run." if native_command.blank?
      unless native_command.length <= MAX_NATIVE_COMMAND_LENGTH
        raise InvalidError, "Native analyzer command must be at most #{MAX_NATIVE_COMMAND_LENGTH} characters."
      end
      raise InvalidError, "Provide the pinned branch to validate against." if branch.blank?
      unless branch.match?(VALID_BRANCH_FORMAT)
        raise InvalidError, "Branch may only contain letters, numbers, dots, slashes, underscores, and dashes."
      end
      if marketplace_entry_id.present? && marketplace_entry.nil?
        raise InvalidError, "The selected marketplace tool was not found for this account."
      end
      raise InvalidError, "The selected marketplace entry is not a tool." if marketplace_entry && !tool_entry?
      raise InvalidError, "The selected tool has no published version." if marketplace_entry && tool_contract.nil?
    end

    def marketplace_entry
      return nil if marketplace_entry_id.blank?

      @marketplace_entry ||= project.account.marketplace_entries.active.find_by(id: marketplace_entry_id)
    end

    def tool_entry?
      marketplace_entry&.entry_type == "tool"
    end

    def tool_image
      return @tool_image if defined?(@tool_image)

      @tool_image = marketplace_entry && tool_contract&.dig("image")
    end

    # @spec PREREQ-EXEC-001
    def capabilities_report
      Capabilities.call(project: project, tool_image: tool_image)
    end

    def active_attempt
      project.prerequisite_execution_validations.active.where(issue: issue).first
    end

    def latest_attempt
      PrerequisiteExecutionValidation.latest_for_issue(issue)
    end

    def existing_succeeded?
      latest_attempt&.succeeded? && latest_attempt.scope_digest == scope_digest
    end

    # An unchanged unavailable attempt (same scope digest, still terminal
    # unavailable) is refreshed in place; its snapshot always carries the
    # latest authorized actions.
    # @spec PREREQ-EXEC-014
    def unchanged_unavailable_attempt?(capabilities)
      return false unless latest_attempt&.unavailable? && latest_attempt.scope_digest == scope_digest

      latest_attempt.update!(capability_snapshot: capabilities.to_h)
      true
    end

    def start_attempt!(capabilities)
      mark_stale_evidence!
      cancel_leftover_runs!
      agent_run = create_validation_run!
      validation = PrerequisiteExecutionValidation.create!(
        project: project,
        issue: issue,
        agent_run: agent_run,
        initiated_by: actor,
        status: "pending",
        branch: branch,
        scope_digest: scope_digest,
        contract: contract_payload,
        capability_snapshot: capabilities.to_h
      )
      enqueuer.call(validation)
      Rails.logger.info(
        message: "prerequisite_executions.validation_started",
        prerequisite_execution_validation_id: validation.id,
        agent_run_id: agent_run.id,
        project_id: project.id,
        issue_id: issue.id,
        branch: branch
      )
      validation
    end

    def record_unavailable_attempt!(capabilities)
      mark_stale_evidence!
      PrerequisiteExecutionValidation.create!(
        project: project,
        issue: issue,
        initiated_by: actor,
        status: "unavailable",
        branch: branch,
        scope_digest: scope_digest,
        contract: contract_payload,
        capability_snapshot: capabilities.to_h,
        finished_at: Time.current
      )
    end

    def mark_stale_evidence!
      latest_attempt.mark_stale! if latest_attempt && latest_attempt.scope_digest != scope_digest
    end

    # A prior attempt whose run never reached a terminal status (crashed
    # attempt, discarded job) would otherwise block the per-issue active-run
    # slot for this goal; cancel the leftover before starting fresh.
    def cancel_leftover_runs!
      AgentRun.where(project: project, issue: issue, goal: "prerequisite_validation")
        .where(status: AgentRun::UNFINISHED_STATUSES)
        .update_all(status: "cancelled", completed_at: Time.current, updated_at: Time.current)
    end

    def create_validation_run!
      AgentRun.create!(
        project: project,
        issue: issue,
        initiating_user: actor,
        agent_type: "internal_agent",
        synthetic: true,
        goal: "prerequisite_validation",
        custom_prompt: "Collect prerequisite execution evidence for #{project.full_name}##{issue.github_number}",
        trigger_type: "manual",
        status: "running",
        branch_name: branch,
        started_at: Time.current,
        # Default-deny ingress with no exception grants: the validation run
        # accepts no inbound exposure (EXEC-INGRESS contract).
        external_metadata: {}
      )
    end

    def contract_payload
      steps = [ { "key" => PrerequisiteExecutionValidation::NATIVE_ANALYZER_STEP, "command" => native_command } ]
      steps << { "key" => PrerequisiteExecutionValidation::TOOL_SIDECAR_STEP } if tool_contract

      {
        "branch" => branch,
        "native_command" => native_command,
        "tool" => tool_contract,
        "steps" => steps
      }
    end

    def tool_contract
      return nil unless marketplace_entry && tool_entry?

      version = marketplace_entry.current_version
      return nil unless version

      artifact = version.canonical_artifact || {}
      {
        "marketplace_entry_id" => marketplace_entry.id,
        "marketplace_entry_version_id" => version.id,
        "name" => marketplace_entry.name,
        "image" => artifact["image"]
      }
    end

    def scope_digest
      @scope_digest ||= begin
        tool = tool_contract || {}
        components = [
          branch,
          native_command,
          tool["marketplace_entry_id"],
          tool["marketplace_entry_version_id"],
          capabilities_report.tool_flag_enabled
        ]
        Digest::SHA256.hexdigest(components.join("\n"))
      end
    end

    def unavailable_message
      "No compatible execution environment or required authorization. Resolve the listed setup actions, then start again."
    end
  end
end
