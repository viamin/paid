# frozen_string_literal: true

module ProjectDelegation
  # The decision contract for downstream work after intent is settled. This
  # service answers whether Paid may take one decision class; it never grants
  # execution authority. Execution remains governed by the RDR-077/RDR-078
  # phase and bounded-action contracts.
  #
  # @spec PROJECT-DELEGATION-003
  class ActionPlan
    ACTIONS = ProjectDelegation::Posture::DELEGATED_ACTION_CLASSES.freeze
    RESERVED_KEYS = %w[
      product_behavior requirements scope acceptance_criteria explicit_hold
      release deployment settings_change setting_enablement new_work_lineage
    ].freeze
    COMMON_EVIDENCE = %w[intent_revision acceptance_revision evidence_revision policy_signature lineage].freeze
    REQUIRED_EVIDENCE = {
      "bounded_implementation_choice" => %w[alternatives selected_option rationale tests review_evidence],
      "focused_followup_ownership" => %w[finding affected_scope evidence owner completion_dependency follow_up_link execute_follow_up],
      "technical_stop_recovery" => %w[failure_classification attempted_recovery current_checks budget_evidence],
      "evidence_gated_issue_closure" => %w[required_checks review_merge_state dependencies open_followups],
      "cycle_analysis_and_repair" => %w[cycle_evidence proposed_repair result recurrence_count]
    }.freeze

    Decision = Data.define(:permitted, :action, :reasons, :audit_event) do
      def permitted? = permitted
      def blocked? = !permitted
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(project:, work_item:, action:, evidence:, actor: nil)
      @project = project
      @work_item = work_item
      @action = action.to_s
      @evidence = evidence.is_a?(Hash) ? evidence.stringify_keys : {}
      @actor = actor
    end

    def call
      reasons = blocking_reasons
      event = Audit::RecordEvent.call(
        action: "project_delegation.action_evaluated",
        actor:,
        subject: work_item,
        metadata: audit_metadata(reasons)
      )
      Decision.new(permitted: reasons.empty?, action:, reasons:, audit_event: event)
    end

    private

    attr_reader :action, :actor, :evidence, :project, :work_item

    def blocking_reasons
      return [ "reserved_action" ] if reserved_action?
      return [ "unsupported_action" ] unless ACTIONS.include?(action)
      return [ "project_mismatch" ] unless work_item&.project_id == project.id
      return [ "posture_not_bounded" ] unless posture.bounded_delivery?
      return [ "action_not_enabled" ] unless posture.enabled_action_classes.include?(action)

      reasons = []
      reasons.concat(missing_evidence)
      reasons << "prohibited_scope" if (RESERVED_KEYS & evidence.keys).any?
      reasons << "lineage_changed" unless lineage_matches?
      reasons << "policy_changed" unless evidence["policy_signature"] == posture.policy_signature
      reasons << "explicit_hold" if truthy?(evidence["explicit_hold"])
      reasons << "assessment_unavailable" if truthy?(evidence["assessment_unavailable"])
      reasons << "material_risk" if truthy?(evidence["material_risk"])
      reasons << "conflicting_evidence" if truthy?(evidence["conflicting_evidence"])
      reasons << "open_material_followup" if action == "evidence_gated_issue_closure" && open_followups?
      reasons << "follow_up_execution_prohibited" if action == "focused_followup_ownership" && truthy?(evidence["execute_follow_up"])
      reasons
    end

    def posture
      @posture ||= ProjectDelegation::Posture.resolve(project)
    end

    def missing_evidence
      (COMMON_EVIDENCE + REQUIRED_EVIDENCE.fetch(action)).uniq.filter do |key|
        value = evidence[key]
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end.map { |key| "missing_#{key}" }
    end

    def lineage_matches?
      expected = Automation::DelegatedActionAdmission.lineage_issue_ids(work_item)
      evidence["lineage"].is_a?(Array) && evidence["lineage"].map(&:to_i).sort == expected
    end

    def open_followups?
      followups = evidence["open_followups"]
      followups.is_a?(Array) && followups.any?
    end

    def reserved_action?
      BoundedDelegatedAction::RESERVED_ACTIONS.include?(action) ||
        %w[product_decision requirements scope acceptance release deployment settings_change].include?(action)
    end

    def truthy?(value)
      value == true || value.to_s == "true"
    end

    def audit_metadata(reasons)
      {
        "action" => action,
        "result" => reasons.empty? ? "permitted" : "focused_decision_required",
        "reasons" => reasons,
        "policy_revision" => posture.revision,
        "policy_signature" => posture.policy_signature,
        "work_item_id" => work_item&.id,
        "lineage" => bounded_lineage,
        "input_evidence_refs" => evidence.keys.sort,
        "output_evidence_refs" => output_evidence_refs,
        "routed_decision" => reasons.empty? ? nil : { "kind" => "focused_decision", "required" => true }
      }.compact
    end

    def bounded_lineage
      Array(evidence["lineage"]).map(&:to_i).first(50)
    end

    def output_evidence_refs
      REQUIRED_EVIDENCE.fetch(action, []).select { |key| evidence.key?(key) }
    end
  end
end
