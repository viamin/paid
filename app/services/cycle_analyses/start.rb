# frozen_string_literal: true

module CycleAnalyses
  class Start
    Result = Data.define(:status, :agent_run, :message) do
      def success? = status == :queued
    end

    def self.call(...) = new(...).call

    def initialize(cycle:, actor:)
      @cycle = cycle
      @actor = actor
    end

    # @spec AUTO-PICK-QUEUE-016
    def call
      AgentRun.transaction do
        lock_occurrence!
        if duplicate_run
          return Result.new(status: :duplicate, agent_run: duplicate_run,
            message: "Cycle analysis already exists for this occurrence.")
        end

        run = create_run!
        CycleAnalysisJob.perform_later(run.id)
        Result.new(status: :queued, agent_run: run, message: "Cycle analysis queued.")
      end
    end

    private

    attr_reader :actor, :cycle

    def lock_occurrence!
      AgentRun.connection.exec_query(AgentRun.sanitize_sql_array([
        "SELECT pg_advisory_xact_lock(?, ?)", 4804, Zlib.crc32(cycle.occurrence) % 2_147_483_647
      ]))
    end

    def duplicate_run
      @duplicate_run ||= cycle.project.agent_runs.for_cycle_analysis_occurrence(cycle.occurrence)
        .find_by(goal: AgentRun::CYCLE_ANALYSIS_GOAL, status: %w[queued running completed])
    end

    def create_run!
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: cycle.project, goal: AgentRun::CYCLE_ANALYSIS_GOAL)
      AgentRun.create!(project: cycle.project, initiating_user: actor, runner_id:, agent_type:, synthetic: true,
        goal: AgentRun::CYCLE_ANALYSIS_GOAL, trigger_type: "manual", status: "queued",
        custom_prompt: "Analyze dependency cycle #{cycle.occurrence}",
        external_metadata: { METADATA_KEY => Snapshot.call(cycle:) })
    end
  end
end
