# frozen_string_literal: true

module IntentConformance
  # Whether a feature PR's HEAD has a current, within-scope conformance
  # verdict (or a matching human-approved bounded exception), for
  # {Automation::Strategies::AutoMerge::Signals#intent_conformance_ok}.
  #
  # Enforcement is gated behind the +intent_conformance_enforcement+ feature
  # flag (default off), standing in for RDR-066's not-yet-built named
  # feature operating mode. A disabled flag or missing HEAD SHA never
  # blocks — rollout gating fails open, not the conformance check itself.
  #
  # @spec INTENT-CONFORMANCE-002 @spec INTENT-CONFORMANCE-003 @spec INTENT-CONFORMANCE-005
  class Signal
    def self.ok?(...) = new(...).ok?

    def initialize(project:, issue:, head_sha:)
      @project = project
      @issue = issue
      @head_sha = head_sha
    end

    def ok?
      return true unless enforced?
      return true if head_sha.blank?
      return true if verdict&.within_scope?

      IntentConformanceDecision.active_bounded_exception?(issue: issue, head_sha: head_sha)
    end

    private

    attr_reader :project, :issue, :head_sha

    def enforced?
      FeatureFlags.enabled?(:intent_conformance_enforcement, project: project)
    end

    def verdict
      @verdict ||= IntentConformanceVerdict.current_for(issue: issue, head_sha: head_sha)
    end
  end
end
