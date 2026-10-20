# frozen_string_literal: true

module ChatInvestigations
  class Run
    class Error < StandardError; end
    class WorkspaceUnavailableError < Error; end

    def self.call(...)
      new(...).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      return unless start

      complete(result_for_investigation)
    rescue StandardError => error
      fail(error)
    end

    private

    attr_reader :investigation

    def start
      investigation.with_lock do
        return false unless investigation.status == "queued"

        if (reason = denial_reason)
          return await_authorization!(reason: reason)
        end

        investigation.update!(status: "running", started_at: Time.current, metadata: investigation.metadata.merge("progress" => "running"))
      end
      ChatInvestigations::Broadcast.call(investigation)
      true
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
      results = Knowledge::Search.call(project: investigation.project, query: investigation.prompt, mode: "hybrid", limit: 10)
      results.fetch(:results, []).map { |entry| entry[:content].to_s }.join("\n\n")
    end

    def experiment_result
      ChatSessions::ProvisionWorkspace.call(chat_session: investigation.chat_session)
      raise WorkspaceUnavailableError, "Isolated workspace is unavailable" unless investigation.chat_session.reload.container_ready?

      "An isolated workspace is ready for this experiment."
    end

    def complete(result)
      settle!(status: "completed", result:)
    end

    def fail(error)
      settle!(status: "failed", result: error.message)
    end

    def settle!(status:, result:)
      investigation.project.with_lock do
        investigation.reload
        return unless investigation.status == "running"

        consume_reserved_budget!
        investigation.update!(status:, result:, finished_at: Time.current, reserved_cost_cents: 0,
          metadata: investigation.metadata.merge("progress" => status))
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
