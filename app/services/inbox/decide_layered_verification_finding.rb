# frozen_string_literal: true

require "digest"

module Inbox
  # Records the operator's assessment-only Inbox choice. Repair and canonical
  # clarification persistence remain separately authorized operations.
  # @spec LAYERED-VERIFY-015 LAYERED-VERIFY-016 LAYERED-VERIFY-018
  class DecideLayeredVerificationFinding
    ACTIONS = %w[request_repair approve_clarification defer].freeze

    class StaleRevisionError < StandardError; end

    def self.call(...) = new(...).call

    def initialize(finding:, user:, action:, reason:, external_revision:)
      @finding = finding
      @user = user
      @action = action.to_s
      @reason = reason.to_s
      @external_revision = external_revision.to_s
    end

    def call
      raise ArgumentError, "select a valid decision" unless ACTIONS.include?(action)
      raise ArgumentError, "decision reason is required" if reason.blank?

      finding.with_lock do
        raise StaleRevisionError, "The obligation source changed; review fresh evidence before deciding." if stale?

        finding.update!(status: action == "defer" ? "deferred" : "open", decision: recorded_decision)
      end
      finding
    end

    private

    attr_reader :action, :external_revision, :finding, :reason, :user

    def stale?
      external_revision != recorded_target_revision ||
        current_obligation_revision != finding.obligation.external_revision.to_s ||
        !obligation_source_matches_evidence?
    end

    def recorded_target_revision
      finding.agent_run.external_metadata.dig("layered_verification", "target_revision").to_s
    end

    def current_obligation_revision
      return current_project_revision if git_revision?(finding.obligation.external_revision)

      Digest::SHA256.hexdigest(current_obligation_source)
    rescue GithubClient::Error, Faraday::Error
      raise StaleRevisionError, "The obligation source could not be verified; try again before deciding."
    end

    def current_project_revision
      @current_project_revision ||= project.client.ref(project.full_name, "heads/#{project.default_branch}").object.sha.to_s
    end

    def current_obligation_source
      project.client.file_content(
        project.full_name, path: finding.obligation.external_identity, ref: current_project_revision
      ).presence || raise(StaleRevisionError, "The obligation source could not be verified; try again before deciding.")
    end

    def git_revision?(revision)
      revision.to_s.match?(/\A[0-9a-f]{40}\z/i)
    end

    def project
      finding.project
    end

    def obligation_source_matches_evidence?
      expected = finding.obligation.reload.external_revision.to_s
      LayeredVerificationCheckResult.where(agent_run: finding.agent_run, obligation: finding.obligation)
        .any? { |result| result.input_revision.values.map(&:to_s).include?(expected) }
    end

    def recorded_decision
      finding.decision.merge(
        "selected_action" => action, "reason" => reason, "decided_by_id" => user.id,
        "decided_at" => Time.current.iso8601, "external_revision" => external_revision
      )
    end
  end
end
