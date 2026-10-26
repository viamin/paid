# frozen_string_literal: true

module TechnicalPrerequisites
  # Creates the fresh, pinned operational run used by an authorized Inbox
  # validation. Commands come only from persisted reviewed requirements.
  # @spec PARTIAL-CLOSEOUT-030
  class StartValidation
    Result = Data.define(:status, :agent_run, :message) do
      def success? = status == :queued
    end

    def self.call(...) = new(...).call

    def initialize(source_run:, requirement:, actor:)
      @source_run = source_run
      @requirement = requirement
      @actor = actor
    end

    def call
      return failure("Select a run with a pinned checkout.") if source_run.base_commit_sha.blank?
      return failure("Select an enabled validation recipe for this project.") unless allowed_requirement?
      return failure("The selected validation recipe has an invalid command.") unless reviewed_command

      run = create_validation_run!
      # Enqueued after the run is committed: the job claims the run by id, and
      # a job that starts before the commit would not find it.
      TechnicalPrerequisiteValidationJob.perform_later(run.id)
      Result.new(status: :queued, agent_run: run, message: "Prerequisite validation queued.")
    end

    private

    attr_reader :actor, :requirement, :source_run

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
        trigger_type: "manual", status: "queued", base_commit_sha: source_run.base_commit_sha,
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
          "source_run_id" => source_run.id
        }
      )
    end

    def copy_runtime_snapshots!(run)
      AgentRun.where(id: run.id).update_all(
        tool_sidecar_snapshot: source_run.tool_sidecar_snapshot,
        mcp_server_snapshot: source_run.mcp_server_snapshot
      )
      run.reload
    end

    # Requirements are reviewed shell recipes. Preserve their text so this
    # validation follows the same `sh -c` execution path as pre-commit checks.
    def reviewed_command
      @reviewed_command ||= requirement.command if requirement.command.is_a?(String) && requirement.command.present?
    end

    def failure(message)
      Result.new(status: :invalid, agent_run: nil, message:)
    end
  end
end
