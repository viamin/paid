# frozen_string_literal: true

module Prerequisites
  # Starts one bounded execution validation for a prerequisite owner issue
  # (#4643): records the authorization-scoped generation, snapshots the cheap
  # policy inputs (flag/allowlist/tool entry) so the operator sees missing
  # authorization actions immediately, checks the project budget, and enqueues
  # the executor. Host readiness is probed by the executor, not here, so the
  # request stays fast.
  #
  # One active validation per issue; a start after a terminal validation is
  # the idempotent retry — a new generation, never a mutation of prior
  # evidence (PREREQ-EVIDENCE-002).
  class StartValidation
    Result = Struct.new(:validation, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, include_tool_sidecar: true, analyzer_command: nil)
      @issue = issue
      @actor = actor
      @include_tool_sidecar = include_tool_sidecar
      @analyzer_command = normalize_analyzer_command(analyzer_command)
    end

    def call
      return failure(:missing_issue, "A prerequisite owner issue is required.") unless issue
      return failure(:missing_project, "The issue has no project.") unless issue.project

      budget = CostBudgets::Check.call(issue.project)
      return failure(:budget_exhausted, "The project's AI budget has been reached (#{budget[:reason]}).") unless budget[:allowed]

      existing = PrerequisiteValidation.open_for_issue(issue)
      return failure(:in_progress, "A validation is already #{existing.status} for ##{issue.github_number}.") if existing

      validation = nil
      PrerequisiteValidation.transaction do
        validation = PrerequisiteValidation.create!(
          account: issue.project.account,
          project: issue.project,
          issue: issue,
          requested_by: actor,
          include_tool_sidecar: include_tool_sidecar?,
          analyzer_command: analyzer_command,
          scope_digest: CapabilityReport.scope_digest_for(project: issue.project),
          capability_snapshot: policy_snapshot
        )
        record_policy_blockers!(validation)
      end

      PrerequisiteValidationJob.perform_later(validation.id)
      Result.new(validation: validation)
    rescue ActiveRecord::RecordNotUnique => e
      raise unless duplicate_active_validation?(e)

      retry
    end

    private

    attr_reader :actor, :analyzer_command, :issue

    def include_tool_sidecar? = @include_tool_sidecar == true

    def normalize_analyzer_command(command)
      normalized = command.to_s.strip
      return nil if normalized.empty?

      normalized
    end

    def duplicate_active_validation?(error)
      error.message.include?("index_prerequisite_validations_one_active_per_issue")
    end

    def selected_tool_entry
      @selected_tool_entry ||= Prerequisites::CapabilityReport
        .new(project: issue.project).selected_tool_entry
    end

    def policy_snapshot
      {
        "tool_sidecars_enabled" => tool_sidecars_enabled?,
        "allowlisted_images" => allowlisted_images,
        "tool_entry" => tool_entry_identity,
        "analyzer_command" => resolved_analyzer_command
      }
    end

    def resolved_analyzer_command = analyzer_command || PrerequisiteValidation::DEFAULT_ANALYZER_COMMAND

    def tool_sidecars_enabled?
      return @tool_sidecars_enabled if defined?(@tool_sidecars_enabled)

      @tool_sidecars_enabled = FeatureFlags.enabled?(:marketplace_tool_sidecars, project: issue.project)
    end

    def allowlisted_images
      @allowlisted_images ||= Containers::McpProvisioner.allowed_images_for_project(issue.project).sort
    end

    def tool_entry_identity
      entry = selected_tool_entry
      return nil unless entry

      {
        "id" => entry.id,
        "name" => entry.name,
        "version" => entry.current_version&.version,
        "version_id" => entry.current_version&.id,
        "image" => entry.current_version&.canonical_artifact.to_h["image"]
      }
    end

    # Policy blockers recorded at start so the Inbox shows the exact
    # authorized action immediately; the executor re-checks each policy input
    # at run time because flags and allowlists can change between start and
    # execution (PREREQ-EVIDENCE-004).
    def record_policy_blockers!(validation)
      if include_tool_sidecar? && !tool_sidecars_enabled?
        validation.record_blocker!(
          check: "tool_sidecar",
          reason: "The marketplace_tool_sidecars rollout flag is off for this tenant; the sidecar interaction cannot run.",
          authorized_action: CapabilityReport::FLAG_ENABLE_ACTION
        )
      end

      entry = selected_tool_entry
      if include_tool_sidecar? && tool_sidecars_enabled?
        if entry.nil?
          validation.record_blocker!(
            check: "tool_sidecar",
            reason: "No active marketplace entry of entry_type \"tool\" exists for this account.",
            authorized_action: CapabilityReport::TOOL_ENTRY_MISSING_ACTION
          )
        elsif !allowlisted_images.include?(entry.current_version&.canonical_artifact.to_h["image"].to_s)
          validation.record_blocker!(
            check: "tool_sidecar",
            reason: "Tool entry #{entry.name} image #{entry.current_version&.canonical_artifact.to_h["image"].inspect} is not in the allowed service images list.",
            authorized_action: "Add #{entry.current_version&.canonical_artifact.to_h["image"]} to this account's allowed " \
              "service images (an admin/owner user-settings action) or publish a tool entry whose image is allowlisted."
          )
        end
      end
    end

    def failure(code, message)
      Result.new(code: code, message: message)
    end
  end
end
