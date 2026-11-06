# frozen_string_literal: true

module PartialCloseouts
  # Resumes a source-closure assessment that failed after the agent's coding
  # work was already pushed.
  #
  # It never re-runs coding and never mints a replacement AgentRun: it
  # re-assesses the exact pushed revision and, only after a successful current
  # assessment, continues with the pull-request publication and closeout steps
  # the original workflow would have run.
  # @spec PARTIAL-CLOSEOUT-043 @spec PARTIAL-CLOSEOUT-045
  class SourceClosureRecovery
    Result = Data.define(:status, :message, :agent_run) do
      def recovered? = status == "recovered"
      def waiting? = status == "waiting"
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, actor: nil)
      @agent_run = agent_run
      @actor = actor
    end

    def call
      agent_run.reload
      return skipped("This run is not waiting for a closeout assessment recovery.") unless SourceClosureRecoveryState.pending?(agent_run)
      return skipped("This run was cancelled; its closeout assessment recovery was abandoned.") if agent_run.status == "cancelled"

      unless SourceClosureRecoveryState.claim(agent_run)
        return skipped("A closeout assessment recovery is already in progress for this run.")
      end

      log_recovery_event("source_closure.recovery_started", actor: actor)

      revision = PushedRevision.call(agent_run: agent_run)
      return handle_revision(revision) unless revision.current?

      return hold_for_operator if execution_held?

      with_assessment_environment { assess_and_publish }
    rescue StandardError => e
      park_with_error(e)
    end

    private

    attr_reader :agent_run, :actor

    def assess_and_publish
      Activities::AssessSourceClosureActivity.new.execute(agent_run_id: agent_run.id)
      publish
    rescue Temporalio::Error::ApplicationError => e
      park_with_error(e)
    end

    # Publication stays gated on the assessment that just succeeded: the pull
    # request body carries the current closeout disposition, and the issue is
    # only completed through the same path the original workflow uses.
    def publish
      pr_result = Activities::CreatePullRequestActivity.new.execute(agent_run_id: agent_run.id)
      reconcile_result = Activities::ReconcilePartialCloseoutActivity.new.execute(agent_run_id: agent_run.id)
      Activities::AdvancePartialCloseoutActivity.new.execute(agent_run_id: agent_run.id)
      publish_issue_evidence(pr_result, reconcile_result)

      SourceClosureRecoveryState.recovered(agent_run, pull_request_url: pr_result[:pull_request_url])
      log_recovery_event("source_closure.recovery_recovered", pull_request_url: pr_result[:pull_request_url])
      Result.new(status: "recovered", message: "Closeout assessment recovered and published.", agent_run: agent_run)
    end

    def publish_issue_evidence(pr_result, reconcile_result)
      pull_request_url = pr_result[:pull_request_url]
      return if pull_request_url.blank?

      if reconcile_result[:gaps_remain]
        Activities::PostPartialCloseoutEvidenceActivity.new.execute(
          agent_run_id: agent_run.id, pull_request_url: pull_request_url
        )
      else
        Activities::UpdateIssueWithPrActivity.new.execute(
          agent_run_id: agent_run.id, pull_request_url: pull_request_url
        )
      end
    end

    def handle_revision(revision)
      if revision.transient?
        park_with_error(revision.message, category: "revision_lookup_unavailable")
      else
        SourceClosureRecoveryState.abandon(agent_run, category: revision.reason, message: revision.message)
        log_recovery_event("source_closure.recovery_abandoned", reason: revision.reason)
        Result.new(status: "abandoned", message: revision.message, agent_run: agent_run)
      end
    end

    # A recovery never bypasses the guards that gate new execution: an
    # explicit operator pause or an exhausted execution budget holds the
    # recovery until a human resolves it.
    # @spec PARTIAL-CLOSEOUT-044
    def execution_held?
      return true if agent_run.project.paused? || agent_run.issue&.paused?
      return true if agent_run.project.quality_paused_at.present?

      agent_run.token_limit_exceeded? || agent_run.token_limit_usage_ratio >= 1.0
    end

    def hold_for_operator
      message = "Execution is held for run #{agent_run.id}; the closeout assessment recovery is waiting for an operator."
      SourceClosureRecoveryState.park(agent_run, category: Llm::PartialCloseoutFailure::EXECUTION_PAUSED, message: message)
      log_recovery_event("source_closure.recovery_held")
      Result.new(status: "waiting", message: message, agent_run: agent_run)
    end

    def park_with_error(error, category: nil)
      SourceClosureRecoveryState.park(agent_run, error: error, category: category)
      log_recovery_event("source_closure.recovery_waiting", error_class: error.class.name)
      Result.new(status: "waiting", message: error.message.to_s.truncate(300), agent_run: agent_run)
    end

    def skipped(message)
      Result.new(status: "skipped", message: message, agent_run: agent_run)
    end

    # Restores the isolated assessment environment when the runner needs one.
    # The container is released again afterwards so a waiting recovery never
    # holds execution resources, and repository code never runs on the host.
    def with_assessment_environment
      return yield unless isolated_environment_required?

      agent_run.provision_execution_environment
      begin
        yield
      ensure
        agent_run.cleanup_execution_environment(force: true)
      end
    end

    def isolated_environment_required?
      runner = agent_run.effective_runner_record
      return false unless runner
      return true if runner.zero_data_retention_enforced?

      !runner.api_key?
    end

    def log_recovery_event(message, **fields)
      Rails.logger.info(
        {
          message: message,
          agent_run_id: agent_run.id,
          project_id: agent_run.project_id,
          actor_id: actor&.id
        }.compact.merge(fields)
      )
    end
  end
end
