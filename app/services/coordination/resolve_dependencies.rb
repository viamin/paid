# frozen_string_literal: true

module Coordination
  # Checks whether all dependency signals have been satisfied for a given
  # agent run. Used by the orchestration layer to decide whether a queued
  # sub-task can proceed.
  #
  # @example
  #   result = Coordination::ResolveDependencies.call(
  #     agent_run: run,
  #     required_run_ids: [older_run.id]
  #   )
  #   result.ready?  # => true / false
  #   result.failed? # => true if any dependency emitted a failure signal
  class ResolveDependencies
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, required_run_ids: [])
      @agent_run = agent_run
      @required_run_ids = Array(required_run_ids).map(&:to_i)
    end

    def call
      return Result.new(ready: true, failed: false) if required_run_ids.empty?

      unless agent_run.parent_workflow_id.present?
        return Result.new(ready: false, failed: false, error: "agent run has no parent_workflow_id")
      end

      failed = AgentCoordinationSignal.any_dependency_failed?(agent_run, required_run_ids: required_run_ids)
      return Result.new(ready: false, failed: true, failed_run_ids: failed_source_ids) if failed

      met = AgentCoordinationSignal.dependencies_met?(agent_run, required_run_ids: required_run_ids)
      Result.new(ready: met, failed: false)
    end

    private

    attr_reader :agent_run, :required_run_ids

    def failed_source_ids
      AgentCoordinationSignal
        .for_workflow(agent_run.parent_workflow_id)
        .by_type("dependency_failed")
        .where(source_agent_run_id: required_run_ids)
        .where("target_agent_run_id = ? OR target_agent_run_id IS NULL", agent_run.id)
        .distinct
        .pluck(:source_agent_run_id)
    end

    class Result
      attr_reader :error, :failed_run_ids

      def initialize(ready:, failed:, error: nil, failed_run_ids: [])
        @ready = ready
        @failed = failed
        @error = error
        @failed_run_ids = failed_run_ids
      end

      def ready? = @ready
      def failed? = @failed
    end
  end
end
