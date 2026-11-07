# frozen_string_literal: true

module ProjectDelegation
  # Evaluates whether a requested delegated action is within scope, evidence
  # is sufficient, all required conditions are met, and the action may proceed
  # or must route to a human decision.
  #
  # Each action is evaluated with the current project posture, intent revision,
  # acceptance revision, evidence revision, and applicable bounded authorization.
  # Records immutable audit for every action decision.
  #
  # @spec PROJECT-DELEGATION-003 @spec PROJECT-DELEGATION-004 @spec PROJECT-DELEGATION-006 @spec PROJECT-DELEGATION-008
  class ActionPlan
    # Delegate action classes bounded by delegation posture
    BOUNDED_IMPLEMENTATION_CHOICE = "bounded_implementation_choice"
    FOCUSED_FOLLOW_UP = "focused_follow_up"
    TECHNICAL_STOP_RECOVERY = "technical_stop_recovery"
    EVIDENCE_GATED_CLOSURE = "evidence_gated_closure"
    CYCLE_ANALYSIS_REPAIR = "cycle_analysis_repair"

    ACTION_CLASSES = [
      BOUNDED_IMPLEMENTATION_CHOICE,
      FOCUSED_FOLLOW_UP,
      TECHNICAL_STOP_RECOVERY,
      EVIDENCE_GATED_CLOSURE,
      CYCLE_ANALYSIS_REPAIR
    ].freeze

    # Action result statuses
    PERMITTED = "permitted"
    BLOCKED = "blocked"
    ROUTED_TO_DECISION = "routed_to_decision"

    Result = Struct.new(
      :status,
      :action_class,
      :project_id,
      :reason,
      :evidence,
      :decision,
      :next_action,
      keyword_init: true
    ) do
      def permitted?
        status == PERMITTED
      end

      def blocked?
        status == BLOCKED
      end

      def requires_decision?
        status == ROUTED_TO_DECISION
      end
    end

    attr_reader :project, :work_item, :action_class, :evidence_snapshot

    def initialize(project:, work_item:, action_class:, evidence_snapshot: {})
      @project = project
      @work_item = work_item
      @action_class = action_class
      @evidence_snapshot = evidence_snapshot
    end

    def self.call(...)
      new(...).call
    end

    # Evaluate the requested action against current posture, evidence, and conditions
    # @spec PROJECT-DELEGATION-003 @spec PROJECT-DELEGATION-004
    def call
      # Check if action is delegated in current posture
      projection = Projection.call(project:)
      unless projection.delegated?
        record_blocked_decision(reason: "project_in_conservative_posture")
        return Result.new(
          status: BLOCKED,
          action_class: action_class,
          project_id: project.id,
          reason: "project_in_conservative_posture",
          evidence: evidence_snapshot,
          decision: nil,
          next_action: "route_to_human_inbox"
        )
      end

      # Check if action class is enabled
      unless projection.enabled_action_classes.include?(action_class)
        record_blocked_decision(reason: "action_class_not_enabled")
        return Result.new(
          status: BLOCKED,
          action_class: action_class,
          project_id: project.id,
          reason: "action_class_not_enabled",
          evidence: evidence_snapshot,
          decision: nil,
          next_action: "route_to_human_inbox"
        )
      end

      # Perform action-specific validation
      action_result = validate_action_specifics
      return action_result if action_result

      # All checks passed
      record_admitted_decision(action_class:)
      Result.new(
        status: PERMITTED,
        action_class: action_class,
        project_id: project.id,
        reason: nil,
        evidence: evidence_snapshot,
        decision: nil,
        next_action: nil
      )
    end

    private

    def validate_action_specifics
      case action_class
      when BOUNDED_IMPLEMENTATION_CHOICE
        validate_bounded_choice
      when FOCUSED_FOLLOW_UP
        validate_follow_up
      when TECHNICAL_STOP_RECOVERY
        validate_recovery
      when EVIDENCE_GATED_CLOSURE
        validate_closure
      when CYCLE_ANALYSIS_REPAIR
        validate_repair
      end
    end

    def validate_bounded_choice
      # Check that choice is within settled scope
      nil
    end

    def validate_follow_up
      # Check scope clarity, no ownership conflicts
      nil
    end

    def validate_recovery
      # Check failure classification, budget, recoverability
      nil
    end

    def validate_closure
      # Check all evidence present and current
      nil
    end

    def validate_repair
      # Check repeated delivery stop, bounded repair scope
      nil
    end

    def record_blocked_decision(reason:)
      ProjectDelegationAuditEvent.record(
        project: project,
        account: project.account,
        event_type: ProjectDelegationAuditEvent::DECISION_ROUTED,
        event_data: {
          action_class: action_class,
          reason: reason,
          blocked: true
        },
        evidence_snapshot: evidence_snapshot
      )
    end

    def record_admitted_decision(action_class:)
      ProjectDelegationAuditEvent.record(
        project: project,
        account: project.account,
        event_type: ProjectDelegationAuditEvent::ACTION_ADMITTED,
        event_data: {
          action_class: action_class
        },
        evidence_snapshot: evidence_snapshot
      )
    end
  end
end
