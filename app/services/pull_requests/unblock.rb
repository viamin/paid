# frozen_string_literal: true

module PullRequests
  # Clears an escalation on behalf of the owner, without waiting for a scan
  # cycle. Deciding what the pull request needs next is the scanner's job, so
  # this queues no run — clearing the hold returns the PR to the scan, which
  # picks the work on its next pass.
  #
  # @spec PR-ESCALATION-014 @spec PR-ESCALATION-015 @spec PR-ESCALATION-016
  class Unblock
    ESCALATED_LABEL = "paid-escalated"

    Result = Data.define(:success, :error, :pull_request) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(pull_request:, draft: false)
      @pull_request = pull_request
      @draft = draft
    end

    def call
      error = nil

      # Guards run inside the lock against reloaded state: a concurrent
      # MarkEscalatedActivity or a PR closing between render and click would
      # otherwise pass a stale check and clear anyway.
      pull_request.with_lock do
        if pull_request.github_state != "open"
          error = :not_open
        elsif !pull_request.escalated_phase?
          error = :not_escalated
        else
          pull_request.clear_escalation!(draft: draft)
        end
      end

      return failure(error) if error

      remove_escalated_label
      Result.new(success: true, error: nil, pull_request: pull_request)
    end

    private

    attr_reader :pull_request, :draft

    # Best-effort: the local clearing is what unblocks automation, and a GitHub
    # failure must not leave it half-applied. A stale label on a PR that is no
    # longer escalated does not re-escalate anything, and the next sync
    # reconciles it.
    def remove_escalated_label
      project = pull_request.project
      client = project.client
      return unless client

      client.remove_label_from_issue(project.full_name, pull_request.github_number, ESCALATED_LABEL)
    rescue GithubClient::Error, Faraday::Error => e
      Rails.logger.warn(
        message: "pr_escalation.label_removal_failed",
        issue_id: pull_request.id,
        pr_number: pull_request.github_number,
        error_class: e.class.name,
        error: e.message
      )
    end

    def failure(error)
      Result.new(success: false, error: error, pull_request: pull_request)
    end
  end
end
