# frozen_string_literal: true

require "digest"

module PartialCloseouts
  # Confirms that a GitHub repair has returned through the authoritative issue
  # sync before the repair run is presented as complete.
  class ConfirmSync
    def self.call(...) = new(...).call

    def initialize(project:, synced_issue_ids:)
      @project = project
      @synced_issue_ids = synced_issue_ids
    end

    def call # @spec PARTIAL-CLOSEOUT-039 PARTIAL-CLOSEOUT-040
      pending_runs.each_with_object([]) do |run, outcomes|
        outcomes << confirm(run)
      end
    end

    private

    attr_reader :project

    def pending_runs
      pending = { sync_confirmation: { status: "pending" } }
      project.agent_runs.where(issue_id: synced_issue_ids)
        .where("reconciliation @> ?::jsonb", pending.to_json)
    end

    attr_reader :synced_issue_ids

    def confirm(run)
      reconciliation = run.reconciliation.to_h.deep_stringify_keys
      sync = reconciliation.fetch("sync_confirmation").deep_stringify_keys
      if body_matches?(run, sync)
        resolve(run, reconciliation, sync)
      elsif sync.fetch("attempts", 0).to_i + 1 >= sync.fetch("max_attempts", PartialCloseouts::Reconcile::MAX_SYNC_CONFIRMATION_ATTEMPTS).to_i
        exhaust(run, reconciliation, sync)
      else
        retry_later(run, reconciliation, sync)
      end
    end

    def body_matches?(run, sync)
      issue = project.issues.find(run.issue_id)
      Digest::SHA256.hexdigest(issue.body.to_s) == sync.fetch("expected_body_digest")
    end

    def resolve(run, reconciliation, sync)
      status = Array(reconciliation.dig("assessment", "gaps")).any? { |gap| gap["kind"] == "human" || gap["kind"] == "external" } ? "awaiting_operator" : "reconciled"
      update(run, reconciliation, sync.merge("status" => "confirmed", "confirmed_at" => Time.current.iso8601), status)
      :confirmed
    end

    def retry_later(run, reconciliation, sync)
      attempts = sync.fetch("attempts", 0).to_i + 1
      update(run, reconciliation, sync.merge("attempts" => attempts, "last_checked_at" => Time.current.iso8601), "pending_sync")
      :pending
    end

    def exhaust(run, reconciliation, sync)
      attempts = sync.fetch("attempts", 0).to_i + 1
      update(run, reconciliation, sync.merge(
        "status" => "exhausted", "attempts" => attempts, "exhausted_at" => Time.current.iso8601,
        "resolution" => "manual_sync_review"
      ), "retryable_failure")
      Rails.logger.warn(message: "partial_closeouts.sync_confirmation_exhausted", project_id: project.id,
        issue_id: run.issue_id, agent_run_id: run.id, attempts: attempts)
      :exhausted
    end

    def update(run, reconciliation, sync, status)
      run.update!(reconciliation: reconciliation.merge("sync_confirmation" => sync, "status" => status))
    end
  end
end
