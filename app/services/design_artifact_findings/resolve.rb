# frozen_string_literal: true

module DesignArtifactFindings
  # Records an operator's explicit finding decision against the inspected
  # revision. This deliberately does not claim the underlying document or
  # implementation is repaired; reconciliation remains the verifier.
  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  class Resolve
    STATES = %w[assigned deferred dismissed].freeze

    def self.call(...) = new(...).call

    def initialize(finding:, user:, state:, reason:, revision:, issue: nil)
      @finding = finding
      @user = user
      @state = state.to_s
      @reason = reason.to_s.strip
      @revision = revision.to_s
      @issue = issue
    end

    def call
      finding.with_lock do
        validate!
        finding.update!(
          status: state, resolution_state: state, resolution_reason: reason,
          resolution_actor: user, resolution_issue: issue,
          resolution_metadata: { "revision" => revision, "decided_at" => Time.current.iso8601 }
        )
      end
      finding
    end

    private

    attr_reader :finding, :issue, :reason, :revision, :state, :user

    def validate!
      raise ArgumentError, "unknown resolution state" unless state.in?(STATES)
      raise ArgumentError, "a reason is required" if reason.blank?
      raise ArgumentError, "finding changed; reload before deciding" unless finding.revision == revision
      raise ArgumentError, "linked issue must belong to this project" if issue && issue.project_id != finding.project_id
      raise ArgumentError, "an issue is required when assigning work" if state == "assigned" && issue.nil?
    end
  end
end
