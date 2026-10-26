# frozen_string_literal: true

require "shellwords"

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
      return failure("The selected validation recipe has an invalid command.") unless parsed_command

      run = AgentRun.transaction do
        create_run!.tap do |created_run|
          copy_runtime_snapshots!(created_run)
          TechnicalPrerequisiteValidationJob.perform_later(created_run.id)
        end
      end
      Result.new(status: :queued, agent_run: run, message: "Prerequisite validation queued.")
    end

    private

    attr_reader :actor, :requirement, :source_run

    def allowed_requirement?
      PreCommitRequirement.resolve(project: source_run.project, user: actor).any? { |candidate| candidate.id == requirement.id }
    end

    def create_run!
      AgentRun.create!(
        project: source_run.project, issue: source_run.issue, initiating_user: actor,
        runner: source_run.runner, agent_type: "internal_agent", synthetic: true,
        goal: "create_pr", custom_prompt: "Validate technical prerequisite with #{requirement.name}",
        trigger_type: "manual", status: "queued", base_commit_sha: source_run.base_commit_sha,
        branch_name: "prerequisite-validation-#{SecureRandom.hex(6)}",
        external_metadata: validation_metadata
      )
    end

    def validation_metadata
      source_run.external_metadata.slice("runtime_image").merge(
        "technical_prerequisite_validation" => {
          "requirement_id" => requirement.id,
          "requirement_name" => requirement.name,
          "command" => parsed_command,
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

    def parsed_command
      @parsed_command ||= Shellwords.split(requirement.command).presence
    rescue ArgumentError
      nil
    end

    def failure(message)
      Result.new(status: :invalid, agent_run: nil, message:)
    end
  end
end
