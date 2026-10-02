# frozen_string_literal: true

module FeatureIntents
  # Releases only a still-current human approval after every required design
  # artifact is merged. GitHub reconciliation supplies the resulting default
  # branch revision; this service never infers approval from a bot merge.
  # @spec FEATURE-APPROVAL-016
  class Release
    Result = Data.define(:released, :reason) do
      def released? = released
    end

    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:, revision:)
      @feature_intent = feature_intent
      @revision = revision
    end

    def call
      return denied("Feature has no current human approval.") unless feature_intent.approved_waiting_for_merge?
      return denied("Feature has no required design pull requests.") if required_design_prs.empty?
      return denied("Required design pull requests have not all merged.") unless required_design_prs.all?(&:merged?)
      return denied("The human approval does not match current design PR heads.") unless approval_current?
      return denied("Merged repository revision is required.") if revision.blank?

      feature_intent.transaction do
        feature_intent.update!(approved_design_revision: revision, approved_revision_recorded_at: Time.current)
        feature_intent.release!
      end
      Result.new(released: true, reason: nil)
    end

    private

    attr_reader :feature_intent, :revision

    def required_design_prs
      feature_intent.feature_intent_design_prs.select(&:required?)
    end

    def approval_current?
      required_design_prs.all? { |design_pr| feature_intent.approved_pr_heads[design_pr.pull_request_number.to_s] == design_pr.head_sha }
    end

    def denied(reason) = Result.new(released: false, reason: reason)
  end
end
