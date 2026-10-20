# frozen_string_literal: true

module FeatureIntents
  # @spec FEATURE-APPROVAL-023
  # Read-only projection for list surfaces. It deliberately avoids admission
  # reconciliation so rendering a list cannot mutate release state.
  class IssueHold
    Hold = Data.define(:code, :message)

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      link = links.find do |candidate|
        feature = candidate.feature_intent
        feature.approval_gated? && (!feature.released? || feature.approved_design_revision.blank?)
      end
      return unless link

      hold_for(link.feature_intent)
    end

    private

    attr_reader :issue

    def links
      return issue.feature_intent_issues if issue.association(:feature_intent_issues).loaded?

      issue.feature_intent_issues.includes(:feature_intent).to_a
    end

    def hold_for(feature)
      return Hold.new(code: "feature_revising", message: "Held: feature revising") if feature.revising?
      return Hold.new(code: "no_approved_revision", message: "Held: feature missing approved revision") if feature.approved_design_revision.blank?

      Hold.new(code: "feature_not_released", message: "Held: feature awaiting release")
    end
  end
end
