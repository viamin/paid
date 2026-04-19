# frozen_string_literal: true

module Coordination
  # Creates a coordination signal from one agent run to another (or broadcast
  # to all runs in the same workflow group).
  #
  # @example Notify siblings about changed files
  #   Coordination::SendSignal.call(
  #     source_agent_run: run,
  #     signal_type: "files_changed",
  #     payload: { files: ["app/models/user.rb"] }
  #   )
  class SendSignal
    def self.call(...)
      new(...).call
    end

    def initialize(source_agent_run:, signal_type:, payload: {}, target_agent_run: nil)
      @source_agent_run = source_agent_run
      @signal_type = signal_type
      @payload = payload
      @target_agent_run = target_agent_run
    end

    def call
      unless source_agent_run.parent_workflow_id.present?
        return Result.new(success: false, error: "source run has no parent_workflow_id")
      end

      signal = AgentCoordinationSignal.create!(
        source_agent_run: source_agent_run,
        target_agent_run: target_agent_run,
        parent_workflow_id: source_agent_run.parent_workflow_id,
        signal_type: signal_type,
        payload: payload
      )

      Rails.logger.info(
        message: "coordination.signal_sent",
        signal_id: signal.id,
        signal_type: signal_type,
        source_agent_run_id: source_agent_run.id,
        target_agent_run_id: target_agent_run&.id,
        parent_workflow_id: source_agent_run.parent_workflow_id
      )

      Result.new(success: true, signal: signal)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, error: e.message)
    end

    private

    attr_reader :source_agent_run, :signal_type, :payload, :target_agent_run

    class Result
      attr_reader :signal, :error

      def initialize(success:, signal: nil, error: nil)
        @success = success
        @signal = signal
        @error = error
      end

      def success? = @success
    end
  end
end
