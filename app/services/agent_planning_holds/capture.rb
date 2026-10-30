# frozen_string_literal: true

module AgentPlanningHolds
  # Records a direct proxy write before later reconciliation can mistake the
  # shared GitHub label for an operator's hold. A contract is optional at the
  # boundary: an absent or malformed one deliberately becomes review work.
  # @spec CONFIDENCE-DELIVERY-018
  class Capture
    LABEL = FeatureIntents::ReleaseIssue::PLANNING_LABEL

    def self.call(...) = new(...).call

    def initialize(project:, agent_run:, issue_number:, label_preexisting:, contract: {})
      @project = project
      @agent_run = agent_run
      @issue_number = issue_number
      @label_preexisting = label_preexisting
      @contract = contract.to_h.deep_stringify_keys
    end

    def call
      return unless agent_run.project_id == project.id

      issue = project.issues.find_by(github_number: issue_number)

      hold = AgentPlanningHold.create_or_find_by!(project:, remote_issue_number: issue_number, label: LABEL) do |record|
        record.account = project.account
        record.issue = issue
        record.agent_run = agent_run
      end
      hold.update!(issue:) if issue && hold.issue_id != issue.id
      hold.with_lock { apply_contract(hold) }
      RequestReview.call(hold:) if hold.status == "needs_review"
      hold
    end

    private

    attr_reader :project, :agent_run, :issue_number, :contract, :label_preexisting

    def apply_contract(hold)
      return hold.update!(agent_run: agent_run) if hold.paid_owned? || label_preexisting || contract.empty?

      hold.update!(
        agent_run: agent_run,
        task_kind: contract["task_kind"],
        reason: contract["reason"],
        release_condition: contract_hash("release_condition"),
        evidence: contract_hash("evidence"),
        operator_override: ActiveModel::Type::Boolean.new.cast(contract["operator_override"]) == true,
        status: complete_contract? ? "held" : "needs_review"
      )
    end

    def complete_contract?
      contract["task_kind"].present? && contract["reason"].present? &&
        contract["release_condition"].is_a?(Hash) && contract["release_condition"].present? &&
        contract.dig("evidence", "scope_revision").present? && supported_release_condition?
    end

    def supported_release_condition?
      contract.dig("release_condition", "kind").in?(AgentPlanningHold::SUPPORTED_RELEASE_CONDITION_KINDS)
    end

    def contract_hash(key)
      contract[key].is_a?(Hash) ? contract[key] : {}
    end

  end
end
