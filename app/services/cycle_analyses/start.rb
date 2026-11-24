# frozen_string_literal: true

module CycleAnalyses
  class Start
    # Automatic attempts per cycle fingerprint: each unchanged occurrence
    # earns at most one automatic run anyway, and this cap keeps a recurring
    # or flapping graph from driving unbounded analysis cost.
    # @spec AUTO-PICK-QUEUE-025
    AUTOMATIC_RUNS_PER_FINGERPRINT = 3

    Result = Data.define(:status, :agent_run, :message) do
      def success? = status == :queued
    end

    def self.call(...) = new(...).call

    def initialize(cycle:, actor:, trigger: :manual)
      @cycle = cycle
      @actor = actor
      @trigger = trigger.to_s
      raise ArgumentError, "trigger must be one of #{AgentRun::TRIGGER_TYPES.join(', ')}" unless AgentRun::TRIGGER_TYPES.include?(@trigger)
    end

    # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-025
    def call
      AgentRun.transaction do
        lock_occurrence!
        return automatic_duplicate if automatic? && automatic_attempt
        return automatic_recurrence_stop if automatic? && recurrence_bound_reached?

        if (run = pending_sync_run)
          resume_confirmation!(run)
          CycleAnalysisJob.perform_later(run.id)
          return Result.new(status: :queued, agent_run: run, message: "Cycle repair confirmation queued.")
        end

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

    def automatic? = @trigger == "automatic"

    # One automatic attempt per unchanged occurrence, whatever its outcome:
    # a failed or cancelled automatic analysis is never retried on its own,
    # and a pending-sync confirmation stays with ordinary synchronization.
    # @spec AUTO-PICK-QUEUE-025
    def automatic_attempt
      @automatic_attempt ||= cycle.project.agent_runs.for_cycle_analysis_occurrence(cycle.occurrence)
        .where(goal: AgentRun::CYCLE_ANALYSIS_GOAL)
        .order(created_at: :desc, id: :desc)
        .first
    end

    def recurrence_bound_reached?
      cycle.project.agent_runs.for_cycle_analysis_fingerprint(cycle.fingerprint)
        .where(goal: AgentRun::CYCLE_ANALYSIS_GOAL, trigger_type: "automatic")
        .count >= AUTOMATIC_RUNS_PER_FINGERPRINT
    end

    def automatic_duplicate
      Result.new(status: :duplicate, agent_run: automatic_attempt,
        message: "An analysis already covers this cycle occurrence.")
    end

    def automatic_recurrence_stop
      Result.new(status: :recurrence_bound, agent_run: nil,
        message: "Automatic cycle analysis is bounded for this cycle; start one manually.")
    end

    def lock_occurrence!
      AgentRun.connection.exec_query(AgentRun.sanitize_sql_array([
        "SELECT pg_advisory_xact_lock(?, ?)", 4804, Zlib.crc32(cycle.occurrence) % 2_147_483_647
      ]))
    end

    def duplicate_run
      @duplicate_run ||= cycle.project.agent_runs.for_cycle_analysis_occurrence(cycle.occurrence)
        .find_by(goal: AgentRun::CYCLE_ANALYSIS_GOAL, status: %w[queued running completed])
    end

    def pending_sync_run
      cycle.project.agent_runs.for_cycle_analysis_occurrence(cycle.occurrence)
        .where(goal: AgentRun::CYCLE_ANALYSIS_GOAL, status: "completed")
        .find { |run| run.verification_result.dig(RESULT_KEY, "repair", "status") == "pending_sync" }
    end

    def resume_confirmation!(run)
      run.update!(status: "queued", started_at: nil, completed_at: nil)
    end

    def create_run!
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: cycle.project, goal: AgentRun::CYCLE_ANALYSIS_GOAL)
      AgentRun.create!(project: cycle.project, initiating_user: actor, runner_id:, agent_type:, synthetic: true,
        goal: AgentRun::CYCLE_ANALYSIS_GOAL, trigger_type: @trigger, status: "queued",
        custom_prompt: "Analyze dependency cycle #{cycle.occurrence}",
        external_metadata: { METADATA_KEY => Snapshot.call(cycle:) })
    end
  end
end
