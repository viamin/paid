# frozen_string_literal: true

module FeatureIntents
  # Reconciles the planning holds that Paid owns. An issue may serve several
  # designs, so every unreleased confidence-driven link for the issue is
  # reconciled as one set: the shared GitHub planning hold is removed only
  # after each link's scoped readiness passes. The database transition is
  # committed before the GitHub request so no lock spans a network call; the
  # final write verifies the scope revision that was assessed.
  # @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-004 @spec CONFIDENCE-DELIVERY-006 @spec CONFIDENCE-DELIVERY-009 @spec CONFIDENCE-DELIVERY-017
  class ReleaseIssue
    PLANNING_LABEL = "planning"

    Result = Data.define(:released, :reason) do
      def released? = released
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Result.new(released: true, reason: nil) if confidence_links.empty?
      return hold_for_dependencies unless issue.ready_to_work?
      return reconcile_planning_task if links.empty? && planning_task_link?
      return hold_for_unknown_planning_label if links.empty? && unknown_planning_label?
      return reconcile_released_projection if links.empty?

      readiness_by_link = links.to_h { |link| [ link, assess(link) ] }
      return hold(readiness_by_link) if readiness_by_link.any? { |_link, readiness| !readiness.ready? }
      return hold_for_unknown_planning_label if unknown_planning_label?

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
    # mapping.
    def confidence_links
      @confidence_links ||= FeatureIntentIssue.includes({ feature_intent: :issue_publications }, :prerequisite_mapping)
        .where(issue_id: issue.id)
        .order(:id)
        .select { |link| link.feature_intent.confidence_driven? }
    end

    # Released snapshots are immutable evidence, so only unreleased links
    # reconcile.
    def links
      @links ||= confidence_links.reject { |link| link.release_state == "released" || link.planning_task? }
    end

    def unknown_planning_label?
      issue.labels.include?(PLANNING_LABEL) &&
        !confidence_links.all?(&:workflow_owned_planning_hold?)
    end

    # A shared GitHub label cannot distinguish Paid's implementation hold from
    # an operator hold on the planning task. Preserve it whenever either task
    # is linked to this issue so planning-task eligibility remains independent.
    def planning_task_link?
      confidence_links.any? { |link| planning_task_contract?(link) }
    end

    def planning_task_contract?(link)
      link.current_readiness_mapping.dig("planning_hold", "owner") == FeatureIntentIssue::PAID_HOLD_OWNER &&
        link.current_readiness_mapping.dig("planning_hold", "task_kind") == FeatureIntentIssue::PLANNING_TASK_KIND
    end

    # Planning tasks are exempt from implementation readiness, but their link
    # still must clear the durable candidate-state gate before auto-pick can
    # reach RunAdmission. Labels and dependencies are evaluated independently.
    def reconcile_planning_task
      confidence_links.select(&:planning_task?).each do |link|
        link.with_lock do
          next if link.release_state == "released"

          link.update!(release_state: "released", released_at: Time.current, release_error: nil)
        end
      end
      Result.new(released: true, reason: nil)
    end

    def hold_for_unknown_planning_label
      reason = "Planning label ownership is unknown and requires operator reconciliation."
      links.each { |link| mark_held(link, reason) }
      Result.new(released: false, reason:)
    end

    # Every design the issue serves already recorded immutable release
    # evidence, so a planning label that reappears externally is a stale
    # projection of a satisfied contract (CONFIDENCE-DELIVERY-006): the label
    # is a default auto-pick skip label, and leaving it on would hold ready
    # work indefinitely. Reconcile it without re-touching snapshots.
    def reconcile_released_projection
      return Result.new(released: true, reason: nil) unless issue.labels.include?(PLANNING_LABEL)

      remove_planning_hold
      issue.update!(labels: issue.labels - [ PLANNING_LABEL ])
      Result.new(released: true, reason: nil)
    end

    def assess(link)
      ScopedReadiness.call(project: issue.project, mapping: link.current_readiness_mapping)
    end

    # Every blocked link records its own blockers so no design in the set is
    # silently held (CONFIDENCE-DELIVERY-006); the reported reason is the
    # first blocker's.
    def hold(readiness_by_link)
      blocked = readiness_by_link.reject { |_link, readiness| readiness.ready? }
      blocked.each { |link, readiness| mark_held(link, reason_for(readiness)) }
      Result.new(released: false, reason: reason_for(blocked.first[1]))
    end

    # Readiness mappings establish scoped confidence, but dependencies are an
    # independent execution prerequisite shared with RunAdmission. Record the
    # hold on links that have not yet released; released snapshots remain
    # immutable evidence even if a later dependency change retains the label.
    def hold_for_dependencies
      links.each { |link| mark_held(link, "Issue has unresolved dependencies.") }
      Result.new(released: false, reason: "Issue has unresolved dependencies.")
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
      return unless issue.labels.include?(PLANNING_LABEL)

      issue.project.client.remove_label_from_issue(issue.project.full_name, issue.github_number, PLANNING_LABEL)
    rescue GithubClient::NotFoundError
      # The remote label is already absent, so the desired projection is met.
    end

    def finalize_release(snapshots)
      snapshots.each do |link, snapshot|
        result = finalize_link(link, snapshot)
        return result unless result.released?
      end

      issue.update!(labels: issue.labels - [ PLANNING_LABEL ])
      Result.new(released: true, reason: nil)
    end

    def finalize_link(link, snapshot)
      link.with_lock do
        return Result.new(released: false, reason: "Issue scope changed while its planning hold was being released.") unless link.current_readiness_mapping["scope_revision"] == snapshot["scope_revision"]

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
  end
end
