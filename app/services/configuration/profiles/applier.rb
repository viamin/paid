# frozen_string_literal: true

module Configuration
  module Profiles
    # Applies a {Plan} to a {Project} transactionally and idempotently.
    # @spec CONFIG-PROFILES-004
    # @spec CONFIG-PROFILES-007
    #
    # Guarantees (RDR-044):
    # - +transactional+: all writes (project save + activity record) succeed or
    #   all roll back.
    # - +idempotent+: re-applying a plan whose targets already hold is a no-op
    #   (no save, no activity, empty result).
    # - +per-level authorized+: unauthorized levels are skipped and reported
    #   before any write executes.
    # - +returns per-change results+: one hash per applied change
    #   (<tt>{ key:, from:, to:, applied: true }</tt>).
    # - +records activity+ once per apply via {Accounts::RecordActivity} using
    #   the dedicated +configuration_profile.applied+ (or +reverted+) action,
    #   carrying every key's previous value and applied value so the change can
    #   be reversed by {Rollback}.
    class Applier
      APPLIED_ACTION = "configuration_profile.applied"
      REVERTED_ACTION = "configuration_profile.reverted"

      def self.call(...) = new(...).call

      def initialize(plan:, project:, actor:, action: APPLIED_ACTION, label: nil)
        @plan = plan
        @project = project
        @actor = actor
        @action = action
        @label = label
      end

      def call
        raise BlockedError, block_message if plan.blocked?
        return { applied_changes: [], skipped_levels: [] } if plan.no_op?

        skipped_levels = authorization.reject { |entry| entry.fetch("allowed", false) }
        applied = applyable_changes
        return { applied_changes: [], skipped_levels: skipped_levels } if applied.empty?

        context.project.class.transaction do
          persist!(apply_changes!(applied))
          record_activity!(applied, skipped_levels)
        end

        {
          applied_changes: applied.map { |change| result_for(change) },
          skipped_levels:
        }
      end

      private

      attr_reader :plan, :project, :actor, :action, :label

      def context
        @context ||= Context.build(project:, actor:)
      end

      def authorization
        @authorization ||= Authorization.call(actor:, context:, changes: plan.changes)
      end

      def applyable_changes
        skipped = skipped_levels.index_by { |entry| entry.fetch("level") }
        plan.changes.filter do |change|
          next false if skipped.key?(change.level.to_s)
          next false if Settings.read(context, change.key) == change.to

          true
        end
      end

      def skipped_levels
        @skipped_levels ||= authorization.reject { |entry| entry.fetch("allowed", false) }
      end

      def apply_changes!(applied)
        applied.map { |change| Settings.write(context, change.key, change.to) }.uniq
      end

      def persist!(records)
        records.each do |record|
          next unless record.changed?

          record.save!
        end
      end

      def record_activity!(applied, skipped_levels)
        Accounts::RecordActivity.call(
          account: project.account,
          actor: actor,
          action: action,
          subject: project,
          metadata: activity_metadata(applied, skipped_levels)
        )
      end

      def activity_metadata(applied, skipped_levels)
        {
          profile: plan.profile_name,
          label: label || default_label,
          source: "configuration_profile",
          project_name: project.name,
          changed_fields: applied.map { |change| change.key.to_s },
          previous_values: applied.to_h { |change| [ change.key.to_s, change.from ] },
          applied_values: applied.to_h { |change| [ change.key.to_s, change.to ] },
          skipped_levels: skipped_levels
        }
      end

      def default_label
        if action == REVERTED_ACTION
          "Revert #{plan.profile_name} posture"
        else
          "Apply #{plan.profile_name} posture"
        end
      end

      def result_for(change)
        { key: change.key, from: change.from, to: change.to, level: change.level.to_s, applied: true }
      end

      def block_message
        "Cannot apply profile #{plan.profile_name.inspect}: unmet prerequisites: #{plan.unmet_prerequisites.join(', ')}"
      end
    end
  end
end
