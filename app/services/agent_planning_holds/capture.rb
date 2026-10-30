# frozen_string_literal: true

module AgentPlanningHolds
  # Records a direct proxy write before later reconciliation can mistake the
  # shared GitHub label for an operator's hold. An ordinary authenticated write
  # has a durable run-completion contract; malformed supplied contracts remain
  # review work.
  # @spec CONFIDENCE-DELIVERY-018
  class Capture
    LABEL = FeatureIntents::ReleaseIssue::PLANNING_LABEL

    def self.call(...) = new(...).call

    def initialize(project:, agent_run:, issue_number:, label_preexisting:, contract: {}, contract_supplied: nil)
      @project = project
      @agent_run = agent_run
      @issue_number = issue_number
      @label_preexisting = label_preexisting
      @contract = contract.to_h.deep_stringify_keys
      @contract_supplied = contract_supplied.nil? ? @contract.present? : contract_supplied
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

    attr_reader :project, :agent_run, :issue_number, :contract, :contract_supplied, :label_preexisting

    def apply_contract(hold)
      return if hold.paid_owned? || label_preexisting

      contract_to_apply = contract_supplied ? contract : default_contract
      hold.update!(
        agent_run: agent_run,
        task_kind: contract_to_apply["task_kind"],
        reason: contract_to_apply["reason"],
        release_condition: contract_hash(contract_to_apply, "release_condition"),
        evidence: contract_hash(contract_to_apply, "evidence"),
        operator_override: ActiveModel::Type::Boolean.new.cast(contract_to_apply["operator_override"]) == true,
        status: complete_contract?(contract_to_apply) ? "held" : "needs_review"
      )
    end

    def default_contract
      {
        "task_kind" => "agent_run",
        "reason" => "Release after the authenticated agent run finishes.",
        "release_condition" => { "kind" => "agent_run_finished", "agent_run_id" => agent_run.id },
        "evidence" => { "scope_revision" => "agent_run:#{agent_run.id}", "issue_number" => issue_number }
      }
    end

    def complete_contract?(contract)
      contract["task_kind"].present? && contract["reason"].present? &&
        contract["release_condition"].is_a?(Hash) && contract["release_condition"].present? &&
        contract.dig("evidence", "scope_revision").present? && supported_release_condition?(contract) &&
        release_condition_matches_run?(contract)
    end

    def supported_release_condition?(contract)
      contract.dig("release_condition", "kind").in?(AgentPlanningHold::SUPPORTED_RELEASE_CONDITION_KINDS)
    end

    def release_condition_matches_run?(contract)
      return true unless contract.dig("release_condition", "kind") == "agent_run_finished"

      contract.dig("release_condition", "agent_run_id").to_s == agent_run.id.to_s
    end

    def contract_hash(contract, key)
      contract[key].is_a?(Hash) ? contract[key] : {}
    end
  end
end
