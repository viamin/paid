# frozen_string_literal: true

module IntentResolutions
  # Records the human resolution of an intent-conformance decision
  # (RDR-067 §Human decision and amendment). The one-PR implementation
  # exception is structurally bounded by IntentConformanceResolution's
  # validations: it can never carry a product-contract change. When the human
  # changes an approved product commitment, the resolution must be (or open)
  # a design amendment, which routes through amended RDR/LID PRs, human
  # approval, and merge.
  # @spec INTENT-AMENDMENT-001 @spec INTENT-AMENDMENT-002
  class Record
    PRODUCT_CHANGE_KEYS = {
      behavior: :changes_behavior,
      constraints: :changes_constraints,
      scope: :changes_scope,
      acceptance_criteria: :changes_acceptance_criteria
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, pull_request_number:, pr_head_sha:, resolution_type:,
      resolved_by:, reason:, changes: {}, design_amendment: nil)
      @project = project
      @issue = issue
      @pull_request_number = pull_request_number
      @pr_head_sha = pr_head_sha
      @resolution_type = resolution_type
      @resolved_by = resolved_by
      @reason = reason
      @changes = changes
      @design_amendment = design_amendment
    end

    def call
      amendment = amendment_for_resolution

      IntentConformanceResolution.create!(
        project: project,
        issue: issue,
        design_amendment: amendment,
        resolved_by: resolved_by,
        resolution_type: resolution_type,
        pull_request_number: pull_request_number,
        pr_head_sha: pr_head_sha,
        reason: reason,
        **product_change_attributes
      )
    end

    private

    attr_reader :project, :issue, :pull_request_number, :pr_head_sha, :resolution_type,
      :resolved_by, :reason, :changes, :design_amendment

    def amendment_for_resolution
      return design_amendment if design_amendment
      return unless resolution_type == "design_amendment"

      DesignAmendments::Open.call(
        feature_intent: feature_intent_for(issue),
        reason: reason,
        drift_evidence: { "changed_claims" => changed_claims }
      )
    end

    def feature_intent_for(target_issue)
      target_issue.feature_intent || raise(ArgumentError, "issue #{target_issue.id} has no feature intent to amend")
    end

    def changed_claims
      PRODUCT_CHANGE_KEYS.select { |_key, flag| product_change_attributes[flag] }
        .keys.map { |key| "Approved #{key.to_s.humanize.downcase} changes under this amendment" }
    end

    def product_change_attributes
      @product_change_attributes ||= PRODUCT_CHANGE_KEYS
        .to_h { |key, flag| [ flag, ActiveModel::Type::Boolean.new.cast(changes[key]) == true ] }
    end
  end
end
