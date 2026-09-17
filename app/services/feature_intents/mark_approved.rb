# frozen_string_literal: true

module FeatureIntents
  # Records a human's Mark approved decision. This is the single choke point
  # for RDR-066 "Approval sources and revision binding": both the Inbox
  # action and any future direct-GitHub-merge reconciliation (#3865) call
  # through here, so authorization and readiness are enforced identically
  # regardless of source — "a direct human merge counts only after readiness
  # and authorized-actor checks."
  # @spec FEATURE-APPROVAL-004 @spec FEATURE-APPROVAL-005 @spec FEATURE-APPROVAL-007
  class MarkApproved
    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:, actor:, source: "inbox")
      @feature_intent = feature_intent
      @actor = actor
      @source = source
    end

    def call
      raise NotAuthorizedError, "user #{actor.id} is not authorized to approve feature intent #{feature_intent.id}" unless authorized?

      readiness = ApprovalReadiness.call(feature_intent: feature_intent)
      raise NotReadyError.new("feature intent #{feature_intent.id} is not ready for approval", blockers: readiness.blockers) unless readiness.ready?

      feature_intent.record_approval!(by: actor, pr_heads: current_pr_heads).tap { log_approval }
    end

    private

    attr_reader :feature_intent, :actor, :source

    def authorized?
      FeatureIntentPolicy.new(actor, feature_intent).approve?
    end

    def current_pr_heads
      feature_intent.feature_intent_design_prs.to_h { |design_pr| [ design_pr.pull_request_number.to_s, design_pr.head_sha ] }
    end

    def log_approval
      Rails.logger.info(
        message: "feature_intents.mark_approved",
        feature_intent_id: feature_intent.id,
        project_id: feature_intent.project_id,
        approved_by_id: actor.id,
        source: source
      )
    end

    class NotAuthorizedError < StandardError; end

    class NotReadyError < StandardError
      attr_reader :blockers

      def initialize(message, blockers:)
        super(message)
        @blockers = blockers
      end
    end
  end
end
