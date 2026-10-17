# frozen_string_literal: true

module FeatureIntents
  # Reconciles the single planning hold that Paid owns. The database transition
  # is committed before the GitHub request so no lock spans a network call; the
  # final write verifies the scope revision that was assessed.
  # @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-004 @spec CONFIDENCE-DELIVERY-006 @spec CONFIDENCE-DELIVERY-009
  class ReleaseIssue
    Result = Data.define(:released, :reason) do
      def released? = released
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Result.new(released: true, reason: nil) unless link&.feature_intent&.confidence_driven?

      readiness = ScopedReadiness.call(project: issue.project, mapping: link.readiness_mapping)
      return hold(readiness) unless readiness.ready?

      snapshot = release_snapshot(readiness)
      mark_pending(snapshot)
      remove_planning_hold
      finalize_release(snapshot)
    rescue StandardError => error
      record_failure(error)
      Result.new(released: false, reason: "Planning-hold reconciliation failed: #{error.message}")
    end

    private

    attr_reader :issue

    def link
      @link ||= FeatureIntentIssue.includes(:feature_intent).find_by(issue_id: issue.id)
    end

    def hold(readiness)
      link.with_lock do
        link.update!(release_state: "held", release_error: readiness.blockers.map(&:message).join(" "))
      end
      Result.new(released: false, reason: readiness.blockers.map(&:message).join(" "))
    end

    def release_snapshot(readiness)
      readiness.snapshot.merge(
        "delivery_policy" => link.feature_intent.delivery_policy,
        "issue_id" => issue.id,
        "issue_number" => issue.github_number
      )
    end

    def mark_pending(snapshot)
      link.with_lock do
        link.update!(release_state: "pending", release_snapshot: snapshot, release_error: nil)
      end
    end

    def remove_planning_hold
      return unless issue.labels.include?(planning_label)

      issue.project.client.remove_label_from_issue(issue.project.full_name, issue.github_number, planning_label)
    end

    def finalize_release(snapshot)
      link.with_lock do
        return Result.new(released: false, reason: "Issue scope changed while its planning hold was being released.") unless link.readiness_mapping["scope_revision"] == snapshot["scope_revision"]

        link.update!(release_state: "released", release_snapshot: snapshot, released_at: Time.current, release_error: nil)
        issue.update!(labels: issue.labels - [ planning_label ])
      end
      Result.new(released: true, reason: nil)
    end

    def record_failure(error)
      return unless link

      link.with_lock { link.update!(release_state: "reconciliation_failed", release_error: error.message) }
    end

    def planning_label = "planning"
  end
end
