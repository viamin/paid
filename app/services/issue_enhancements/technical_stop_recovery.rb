# frozen_string_literal: true

module IssueEnhancements
  # Claims one delayed automatic retry for a technical enhancement stop. The
  # failed run is the durable provenance; manual-review copy is presentation.
  # @spec ISSUE-ENHANCEMENT-021
  class TechnicalStopRecovery
    MAX_ATTEMPTS = 1
    METADATA_KEY = "technical_stop_recovery"

    Result = Data.define(:outcome, :reason, :successor)

    def self.call(...) = new(...).call

    def self.classification(error)
      message = error.to_s
      return "parser" if message.include?("EnhanceIssue agent produced unparseable structured output")
      return "transport" if message.include?(AgentRun::ACTIVITY_TIMEOUT_MESSAGE) ||
        AgentRun::PROVIDER_UNAVAILABLE_KEYWORDS.any? { |keyword| message.downcase.include?(keyword.downcase) }

      nil
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      AgentRun.transaction do
        agent_run.lock!
        issue.lock!
        return skipped(:not_eligible) unless eligible?
        return skipped(:budget_exhausted) unless CostBudgets::Check.call(project)[:allowed]

        successor = AgentRun.create!(successor_attributes)
        agent_run.update_columns(
          external_metadata: agent_run.external_metadata.merge(
            METADATA_KEY => metadata.merge("recovery_claimed_at" => Time.current.iso8601)
          ),
          updated_at: Time.current
        )
        issue.update!(paid_state: "in_progress")
        ProcessRunQueueJob.perform_later
        Result.new(:recovered, :recovered, successor)
      end
    rescue ActiveRecord::RecordNotUnique
      skipped(:active_work)
    end

    private

    attr_reader :agent_run

    delegate :issue, :project, to: :agent_run

    def eligible?
      agent_run.automatic? && agent_run.enhance_issue_goal? && agent_run.status == "failed" &&
        issue.github_state == "open" && issue.trusted? && issue.paid_state == "manual_review" &&
        issue.needs_input_questions.blank? && metadata.fetch("attempt", 0).to_i < MAX_ATTEMPTS &&
        metadata["recovery_claimed_at"].blank? && current_revision? && policy.permitted? && no_active_work?
    end

    def metadata
      agent_run.external_metadata.fetch(METADATA_KEY, {})
    end

    def current_revision?
      metadata["issue_revision"].present? && metadata["issue_revision"] == issue.github_updated_at&.iso8601
    end

    def policy
      @policy ||= Automation::EffectivePolicy.call(
        project:, phase: Automation::Phases::ISSUE_PREPARATION, work_item: issue, trigger: :automatic,
        delegated_action: "review"
      )
    end

    def no_active_work?
      !project.agent_runs.where(issue:, status: AgentRun::UNFINISHED_STATUSES).where.not(id: agent_run.id).exists?
    end

    def successor_attributes
      {
        project:, issue:, initiating_user: agent_run.initiating_user, runner: agent_run.runner,
        agent_type: agent_run.agent_type, custom_prompt: agent_run.custom_prompt, goal: "enhance_issue",
        review_depth_snapshot: agent_run.review_depth_snapshot, trigger_type: "automatic", auto_pick: true,
        status: "queued", external_metadata: agent_run.external_metadata.merge(
          METADATA_KEY => metadata.except("recovery_claimed_at").merge(
            "attempt" => metadata.fetch("attempt", 0).to_i + 1,
            "root_run_id" => metadata.fetch("root_run_id", agent_run.id)
          )
        )
      }
    end

    def skipped(reason)
      Result.new(:skipped, reason, nil)
    end
  end
end
