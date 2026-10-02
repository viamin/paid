# frozen_string_literal: true

module FeatureIntents
  # @spec FEATURE-APPROVAL-015 @spec FEATURE-APPROVAL-016
  # The only initial-release transition. Admission wiring supplies the merged
  # repository revision after provider reconciliation; this service makes the
  # persisted approval and artifact checks atomic with the state change.
  class Release
    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:, merged_revision:, actor: nil)
      @feature_intent = feature_intent
      @merged_revision = merged_revision
      @actor = actor
    end

    def call
      feature_intent.with_lock do
        feature_intent.reload
        validate_release!
        feature_intent.update!(
          status: "released",
          approved_design_revision: merged_revision,
          approved_revision_recorded_at: Time.current
        )
        record_audit_event
      end
      feature_intent
    end

    class NotReadyError < StandardError; end

    private

    attr_reader :feature_intent, :merged_revision, :actor

    def validate_release!
      raise NotReadyError, "feature is not awaiting design merge" unless feature_intent.approved_waiting_for_merge?
      raise NotReadyError, "feature approval is stale" unless approval_current?
      raise NotReadyError, "required design PRs have not all merged" unless required_design_prs.all?(&:merged?)
    end

    def approval_current?
      feature_intent.approved_at.present? && current_pr_heads == feature_intent.approved_pr_heads
    end

    def current_pr_heads
      feature_intent.feature_intent_design_prs.to_h { |design_pr| [ design_pr.pull_request_number.to_s, design_pr.head_sha ] }
    end

    def required_design_prs
      feature_intent.feature_intent_design_prs.select(&:required?)
    end

    def record_audit_event
      Audit::RecordEvent.call(
        action: "feature_intent.released",
        actor: actor,
        subject: feature_intent,
        metadata: {
          from_status: "approved_waiting_for_merge",
          to_status: "released",
          merged_revision: merged_revision,
          approval_revision: feature_intent.feature_intent_approval_revisions.maximum(:revision_number)
        }
      )
    end
  end
end
