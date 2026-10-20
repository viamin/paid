# frozen_string_literal: true

module FeatureIntents
  # @spec FEATURE-APPROVAL-023
  # Read-only projection for list surfaces. It deliberately avoids admission
  # reconciliation so rendering a list cannot mutate release state.
  class IssueHold
    Hold = Data.define(:code, :message)

    def self.call(...) = new(...).call

    def initialize(issue:, feature: nil)
      @issue = issue
      @feature = feature
    end

    def call
      link = links.find { |candidate| feature_matches_scope?(candidate) && feature_held?(candidate, candidate.feature_intent) }
      return unless link

      hold_for(link)
    end

    private

    attr_reader :issue, :feature

    def links
      return issue.feature_intent_issues if issue.association(:feature_intent_issues).loaded?

      issue.feature_intent_issues.includes(:feature_intent).to_a
    end

    # Restrict to the supplied feature scope when one is provided (e.g. the
    # feature-decision view). Without a scope, any linked feature is
    # considered, so the project issue list surfaces the first hold.
    def feature_matches_scope?(candidate)
      feature.nil? || candidate.feature_intent_id == feature.id
    end

    # An issue may serve several designs; approval-gated features project a
    # hold from the feature's release state, while confidence-driven features
    # project a hold from the link's reconciled `release_state` — mirroring
    # `RunAdmission`'s `confidence_admission` branch (CONFIDENCE-DELIVERY-003).
    def feature_held?(candidate, target_feature)
      return true if target_feature.approval_gated? && (!target_feature.released? || target_feature.approved_design_revision.blank?)
      return true if target_feature.confidence_driven? && candidate.release_state != "released"

      false
    end

    def hold_for(link)
      target_feature = link.feature_intent
      return approval_hold_for(target_feature) if target_feature.approval_gated?

      confidence_hold_for(link)
    end

    def approval_hold_for(target_feature)
      return Hold.new(code: "feature_revising", message: "Held: feature revising") if target_feature.revising?
      return Hold.new(code: "no_approved_revision", message: "Held: feature missing approved revision") if target_feature.approved_design_revision.blank?

      Hold.new(code: "feature_not_released", message: "Held: feature awaiting release")
    end

    # The link's `release_error` carries the most recent reconciliation
    # reason; surface it so the rendered badge explains which design is
    # blocking admission without re-running any GitHub write.
    def confidence_hold_for(link)
      case link.release_state
      when "held"
        Hold.new(
          code: "confidence_release_held",
          message: "Held: confidence link holds (#{release_detail(link) || 'planning-hold reconciliation pending'})"
        )
      when "pending"
        Hold.new(code: "confidence_release_pending", message: "Held: confidence link pending planning-hold reconciliation")
      when "reconciliation_failed"
        Hold.new(
          code: "confidence_release_reconciliation_failed",
          message: "Held: confidence link reconciliation failed (#{release_detail(link) || 'retry the planning hold'})"
        )
      else
        Hold.new(code: "confidence_release_unreleased", message: "Held: confidence link awaiting release")
      end
    end

    def release_detail(link)
      link.release_error.to_s.strip.truncate(120).presence
    end
  end
end
