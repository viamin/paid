# frozen_string_literal: true

module FeatureIntents
  # Reconciles the planning holds that Paid owns. An issue may serve several
  # designs, so every unreleased confidence-driven link for the issue is
  # reconciled as one set: the shared GitHub planning hold is removed only
  # after each link's scoped readiness passes. The database transition is
  # committed before the GitHub request so no lock spans a network call; the
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
      return Result.new(released: true, reason: nil) if links.empty?

      readiness_by_link = links.to_h { |link| [ link, assess(link) ] }
      return hold(readiness_by_link) if readiness_by_link.any? { |_link, readiness| !readiness.ready? }

      snapshots = readiness_by_link.to_h { |link, readiness| [ link, snapshot_for(link, readiness) ] }
      links.each { |link| mark_pending(link, snapshots[link]) }
      remove_planning_hold
      finalize_release(snapshots)
    rescue StandardError => error
      record_failure(error)
      Result.new(released: false, reason: "Planning-hold reconciliation failed: #{error.message}")
    end

    private

    attr_reader :issue

    # An issue may serve several designs (the issue_id index on the join is
    # not unique); each confidence-driven link owns a distinct readiness
    # mapping. Released snapshots are immutable evidence, so only unreleased
    # links reconcile.
    def links
      @links ||= FeatureIntentIssue.includes(:feature_intent)
        .where(issue_id: issue.id)
        .where.not(release_state: "released")
        .order(:id)
        .select { |link| link.feature_intent.confidence_driven? }
    end

    def assess(link)
      ScopedReadiness.call(project: issue.project, mapping: link.readiness_mapping)
    end

    # Every blocked link records its own blockers so no design in the set is
    # silently held (CONFIDENCE-DELIVERY-006); the reported reason is the
    # first blocker's.
    def hold(readiness_by_link)
      blocked = readiness_by_link.reject { |_link, readiness| readiness.ready? }
      blocked.each { |link, readiness| mark_held(link, reason_for(readiness)) }
      Result.new(released: false, reason: reason_for(blocked.first[1]))
    end

    def mark_held(link, reason)
      link.with_lock { link.update!(release_state: "held", release_error: reason) }
    end

    def reason_for(readiness) = readiness.blockers.map(&:message).join(" ")

    def snapshot_for(link, readiness)
      readiness.snapshot.merge(
        "delivery_policy" => link.feature_intent.delivery_policy,
        "issue_id" => issue.id,
        "issue_number" => issue.github_number
      )
    end

    def mark_pending(link, snapshot)
      link.with_lock do
        link.update!(release_state: "pending", release_snapshot: snapshot, release_error: nil)
      end
    end

    def remove_planning_hold
      return unless issue.labels.include?(planning_label)

      issue.project.client.remove_label_from_issue(issue.project.full_name, issue.github_number, planning_label)
    rescue GithubClient::NotFoundError
      # The remote label is already absent, so the desired projection is met.
    end

    def finalize_release(snapshots)
      snapshots.each do |link, snapshot|
        result = finalize_link(link, snapshot)
        return result unless result.released?
      end

      issue.update!(labels: issue.labels - [ planning_label ])
      Result.new(released: true, reason: nil)
    end

    def finalize_link(link, snapshot)
      link.with_lock do
        return Result.new(released: false, reason: "Issue scope changed while its planning hold was being released.") unless link.readiness_mapping["scope_revision"] == snapshot["scope_revision"]

        link.update!(release_state: "released", release_snapshot: snapshot, released_at: Time.current, release_error: nil)
      end
      Result.new(released: true, reason: nil)
    end

    # A mid-set failure marks only the links that did not finish releasing;
    # links this call already finalized keep their recorded evidence.
    def record_failure(error)
      return if @links.nil?

      @links.each { |link| mark_failed(link, error.message) }
    end

    def mark_failed(link, message)
      link.with_lock do
        next if link.release_state == "released"

        link.update!(release_state: "reconciliation_failed", release_error: message)
      end
    end

    def planning_label = "planning"
  end
end
