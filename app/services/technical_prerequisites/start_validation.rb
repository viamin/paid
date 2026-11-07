# frozen_string_literal: true

module TechnicalPrerequisites
  # Creates the fresh, pinned operational run used by an authorized Inbox
  # validation. Commands come only from persisted reviewed requirements.
  # @spec PARTIAL-CLOSEOUT-032 PARTIAL-CLOSEOUT-042
  class StartValidation
    Result = Data.define(:status, :agent_run, :message) do
      def success? = status == :queued
    end

    def self.call(...) = new(...).call

    def initialize(source_run:, requirement:, actor:, criterion: nil, tool_name: nil)
      @source_run = source_run
      @requirement = requirement
      @actor = actor
      @criterion = criterion
      @tool_name = tool_name
    end

    def call
      return failure("Select a run with a pinned checkout.") if source_run.base_commit_sha.blank?
      return failure("Select the original implementation run, not a prior validation.") if source_run.technical_prerequisite_validation_goal?
      return failure("Select an enabled validation recipe for this project.") unless allowed_requirement?
      return failure("The selected validation recipe has an invalid command.") unless reviewed_command
      return failure("Select a completed implementation run with a produced revision to measure.") if performance_requirement? && current_commit_sha.blank?
      return failure(performance_recipe.error) if performance_requirement? && !performance_recipe.valid?
      return failure("Select an implementation run linked to an issue to measure.") if performance_requirement? && source_run.issue.nil?
      return failure("The linked pull request head changed or is unavailable; performance evidence remains unknown.") if performance_requirement? && !current_revision?

      run, created, pause_message = admit_validation_run
      return failure(pause_message) if pause_message
      # Enqueued after the run is committed: the job claims the run by id, and
      # a job that starts before the commit would not find it.
      TechnicalPrerequisiteValidationJob.perform_later(run.id) if created
      message = created ? "Prerequisite validation queued." : "Equivalent performance measurement already exists; opening it."
      Result.new(status: :queued, agent_run: run, message:)
    end

    private

    attr_reader :actor, :requirement, :source_run, :criterion, :tool_name

    def admit_validation_run
      return [ create_validation_run!, true, nil ] unless performance_requirement?

      source_run.issue.with_lock do
        existing = existing_run
        return [ existing, false, nil ] if existing

        pause_message = TechnicalPrerequisites.scheduler_pause_message(source_run.project)
        return [ nil, false, pause_message ] if pause_message

        [ create_validation_run!, true, nil ]
      end
    end

    def allowed_requirement?
      PreCommitRequirement.resolve(project: source_run.project, user: actor).any? { |candidate| candidate.id == requirement.id }
    end

    def create_validation_run!
      AgentRun.transaction do
        created_run = create_run!
        copy_runtime_snapshots!(created_run)
        created_run
      end
    end

    def create_run!
      AgentRun.create!(
        project: source_run.project, issue: source_run.issue, initiating_user: actor,
        runner: source_run.runner, agent_type: "internal_agent", synthetic: true,
        # A validation run never implements work, so it uses its own goal
        # instead of create_pr: the create_pr feature-intent admission gate
        # would refuse exactly the stalled issues this recovery path exists
        # for, and the admission revision would replace the pinned checkout.
        goal: AgentRun::TECHNICAL_PREREQUISITE_VALIDATION_GOAL,
        custom_prompt: "Validate technical prerequisite with #{requirement.name}",
        trigger_type: "manual", status: "queued", base_commit_sha: validation_base_commit_sha,
        branch_name: "prerequisite-validation-#{SecureRandom.hex(6)}",
        external_metadata: validation_metadata
      )
    end

    def validation_metadata
      source_run.external_metadata.slice("runtime_image").merge(
        RECIPE_KEY => {
          "requirement_id" => requirement.id,
          "requirement_name" => requirement.name,
          "command" => reviewed_command,
          "criterion" => criterion,
          "tool_name" => tool_name,
          "source_run_id" => source_run.id,
          "performance_measurement" => performance_recipe.recipe
        }
      )
    end

    def copy_runtime_snapshots!(run)
      AgentRun.where(id: run.id).update_all(
        tool_sidecar_snapshot: selected_tool_sidecars,
        mcp_server_snapshot: criterion.present? ? [] : source_run.mcp_server_snapshot
      )
      run.reload
    end

    def selected_tool_sidecars
      return source_run.tool_sidecar_snapshot if criterion.blank?
      return [] if tool_name.blank?

      source_run.tool_sidecar_snapshot.select { |tool| tool["name"] == tool_name }
    end

    # Requirements are reviewed shell recipes. Preserve their text so this
    # validation follows the same `sh -c` execution path as pre-commit checks.
    def reviewed_command
      @reviewed_command ||= requirement.command if requirement.command.is_a?(String) && requirement.command.present?
    end

    def performance_requirement? = requirement.check_type == "performance_measurement"

    def performance_recipe
      @performance_recipe ||= PerformanceRecipe.call(requirement:, current_commit_sha:)
    end

    # The revision produced by the source implementation run is the "current"
    # side of every before/after comparison, mirroring the base/result
    # distinction used by AgentRuns::ApplicationDiagnostics and
    # VerificationResultRecorder. A completed run's base_commit_sha is the
    # pre-change checkout, so measuring it as current would exclude the very
    # changes under review.
    def current_commit_sha
      @current_commit_sha ||= source_run.result_commit_sha.presence
    end

    def current_revision?
      head_sha = current_pull_request_head_sha
      head_sha.present? && head_sha.casecmp?(current_commit_sha)
    end

    def current_pull_request_head_sha
      pull_request_number = source_run.pull_request_number.presence || source_run.source_pull_request_number
      return if pull_request_number.blank?

      source_run.project.issues.find_by(
        github_number: pull_request_number, is_pull_request: true
      )&.last_scanned_head_sha
    end

    # A performance validation re-checks out the produced revision as its
    # current side, so its clone must start from that revision rather than the
    # pre-change base.
    def validation_base_commit_sha
      performance_requirement? ? current_commit_sha : source_run.base_commit_sha
    end

    def existing_run
      return unless performance_requirement?

      source_run.project.agent_runs.where(issue: source_run.issue, goal: AgentRun::TECHNICAL_PREREQUISITE_VALIDATION_GOAL)
        .order(created_at: :desc).detect do |run|
          run.status.in?(%w[queued running completed]) &&
            run.external_metadata.dig(RECIPE_KEY, "criterion") == criterion &&
            run.external_metadata.dig(RECIPE_KEY, "performance_measurement") == performance_recipe.recipe
        end
    end

    def failure(message)
      Result.new(status: :invalid, agent_run: nil, message:)
    end
  end
end
