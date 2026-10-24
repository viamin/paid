# frozen_string_literal: true

module ChatInvestigations
  class Run
    class Error < StandardError; end
    class WorkspaceUnavailableError < Error; end
    class ExperimentFailedError < Error; end

    INTERRUPTED_RESULT = "Execution was interrupted before completion."
    WORKSPACE_UNAVAILABLE_RESULT = "Isolated workspace is unavailable"
    RESEARCH_RESULT_HEADER = "Knowledge-base search results for this question:"
    NO_RESEARCH_EVIDENCE_RESULT = "No project knowledge-base evidence matched this investigation."

    def self.call(...)
      new(...).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      return unless start

      result = result_for_investigation
      complete(result) if result
    rescue StandardError => error
      fail(error)
    end

    private

    attr_reader :investigation

    def start
      investigation.with_lock do
        return recover_interrupted! if investigation.status == "running"
        return false unless investigation.status == "queued"

        if (reason = denial_reason)
          return await_authorization!(reason: reason)
        end

        investigation.update!(status: "running", started_at: Time.current, metadata: investigation.metadata.merge("progress" => "running"))
      end
      ChatInvestigations::Broadcast.call(investigation)
      true
    end

    # GoodJob's per-job advisory lock guarantees a re-entered Run never races a
    # live execution of the same job, so finding the investigation still
    # "running" means the prior execution died mid-run (deploy restart, OOM
    # kill). Settle it and release the reservation rather than stranding the
    # project budget until a manual cancel.
    def recover_interrupted!
      investigation.update!(
        status: "failed",
        result: INTERRUPTED_RESULT,
        finished_at: Time.current,
        reserved_cost_cents: 0,
        metadata: investigation.metadata.merge("progress" => "failed")
      )
      ChatInvestigations::Broadcast.call(investigation)
      false
    end

    # The queued side effect may outlive the initiating collaborator's project
    # access, so recheck authorization against the project before entering
    # running. Per the question-exploration design, queued work must recheck
    # membership; releasing the reservation and transitioning to
    # awaiting_authorization keeps the project budget intact for collaborators
    # who are still authorized.
    def denial_reason
      return "Execution is currently disabled by policy." unless execution_allowed?
      return "The original author no longer has access to this project." unless creator_authorized?

      nil
    end

    def await_authorization!(reason:)
      investigation.update!(
        status: "awaiting_authorization",
        reserved_cost_cents: 0,
        metadata: investigation.metadata.merge("authorization_required" => reason)
      )
      ChatInvestigations::Broadcast.call(investigation)
      false
    end

    def execution_allowed?
      project = investigation.project
      !ExecutionControl.enabled.where(scope: "global").exists? &&
        !ExecutionControl.enabled.where(scope: "account", account: project.account).exists? &&
        !ExecutionControl.enabled.where(scope: "project", project:).exists?
    end

    def creator_authorized?
      ProjectPolicy.new(investigation.created_by, investigation.project).explore?
    end

    def result_for_investigation
      return research_result if investigation.kind == "research"

      experiment_result
    end

    def research_result
      contents = Knowledge::Search.call(project: investigation.project, query: investigation.prompt, mode: "hybrid", limit: 10)
        .fetch(:results, []).map { |entry| entry[:content].to_s }.reject(&:blank?)
      return NO_RESEARCH_EVIDENCE_RESULT if contents.blank?

      "#{RESEARCH_RESULT_HEADER}\n\n#{contents.join("\n\n")}"
    end

    # Experiments run their prompt inside the question's isolated workspace and
    # retain the execution output as evidence. A ready session reuses the live
    # container; a pending/provisioning session already has a provision in
    # flight, and provisioning again would orphan the live container for a
    # duplicate (Containers::ProvisionForChat has no readiness guard).
    def experiment_result
      ensure_ready_workspace
      return unless mark_executing!

      execution = ChatInvestigations::ExecuteExperiment.call(investigation:)
      raise ExperimentFailedError, execution.result_text unless execution.success?

      execution.result_text
    end

    def ensure_ready_workspace
      chat_session = investigation.chat_session.reload
      return if chat_session.container_ready?
      if chat_session.container_pending? || chat_session.container_provisioning?
        raise WorkspaceUnavailableError, WORKSPACE_UNAVAILABLE_RESULT
      end

      ChatSessions::ProvisionWorkspace.call(chat_session:)
      raise WorkspaceUnavailableError, WORKSPACE_UNAVAILABLE_RESULT unless chat_session.reload.container_ready?
    end

    # Long work exposes progress: flip the durable progress marker and tell the
    # conversation before the bounded experiment starts. A cancellation that
    # landed between start and here wins — the run stops without executing.
    def mark_executing!
      investigation.with_lock do
        return false unless investigation.status == "running"

        investigation.update!(metadata: investigation.metadata.merge("progress" => "executing"))
      end
      ChatInvestigations::Broadcast.call(investigation)
      true
    end

    def complete(result)
      settle!(status: "completed", result:)
    end

    def fail(error)
      settle!(status: "failed", result: error.message)
    end

    def settle!(status:, result:)
      investigation.project.with_lock do
        investigation.with_lock do
          return unless investigation.status == "running"

          consume_reserved_budget!
          investigation.update!(status:, result:, finished_at: Time.current, reserved_cost_cents: 0,
            metadata: investigation.metadata.merge("progress" => status))
        end
      end
      ChatInvestigations::Broadcast.call(investigation)
    end

    def consume_reserved_budget!
      investigation.project.cost_budgets.hard_stop.where(budget_type: %w[daily monthly]).find_each do |budget|
        budget.record_usage!(investigation.reserved_cost_cents)
      end
    end
  end
end
