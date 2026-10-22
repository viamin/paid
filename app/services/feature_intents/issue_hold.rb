# frozen_string_literal: true

module FeatureIntents
  # @spec FEATURE-APPROVAL-023
  # Read-only projection for list surfaces. It deliberately avoids admission
  # reconciliation so rendering a list cannot mutate release state.
  class IssueHold
    Hold = Data.define(:code, :message)

    # Deterministic badge precedence when several linked features are held:
    # approval-gated holds outrank confidence-driven holds, and within each
    # delivery policy the more specific state outranks the more generic one,
    # so the reported reason never depends on link creation or load order.
    HOLD_SEVERITY = {
      "feature_revising" => 7,
      "no_approved_revision" => 6,
      "feature_not_released" => 5,
      "confidence_release_held" => 4,
      "confidence_release_reconciliation_failed" => 3,
      "confidence_release_pending" => 2,
      "confidence_release_unreleased" => 1
    }.freeze

    def self.call(...) = new(...).call

    def initialize(issue:, feature: nil)
      @issue = issue
      @feature = feature
    end

    def call
      holds = held_links.map { |link| hold_for(link) }
      return if holds.empty?

      holds.max_by { |hold| HOLD_SEVERITY.fetch(hold.code) }
    end

    private

    attr_reader :issue, :feature

    def links
      return issue.feature_intent_issues.sort_by(&:id) if issue.association(:feature_intent_issues).loaded?

      issue.feature_intent_issues.includes(:feature_intent).order(:id).to_a
    end

    def held_links
      links.select { |candidate| feature_matches_scope?(candidate) && feature_held?(candidate) }
    end

    # Restrict to the supplied feature scope when one is provided (e.g. the
    # feature-decision view). Without a scope, any linked feature is
    # considered, so the project issue list surfaces the highest-precedence
    # hold across the issue's linked designs.
    def feature_matches_scope?(candidate)
      feature.nil? || candidate.feature_intent_id == feature.id
    end

    # An issue may serve several designs; approval-gated features project a
    # hold from the feature's release state, while confidence-driven features
    # project a hold from the link's reconciled `release_state` — mirroring
    # `RunAdmission`'s `confidence_admission` branch (CONFIDENCE-DELIVERY-003).
    def feature_held?(candidate)
      target = candidate.feature_intent
      return true if target.approval_gated? && (!target.released? || target.approved_design_revision.blank?)
      return true if target.confidence_driven? && candidate.release_state != "released"

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
