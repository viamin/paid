# frozen_string_literal: true

module Configuration
  module Profiles
    # Applies a {Plan} to a {Project} transactionally and idempotently.
    # @spec CONFIG-PROFILES-004
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
    # - +records activity+ once per apply via {Accounts::RecordActivity}.
    class Applier
      def self.call(...) = new(...).call

      def initialize(plan:, project:, actor:)
        @plan = plan
        @project = project
        @actor = actor
      end

      def call
        raise BlockedError, block_message if plan.blocked?
        return { applied_changes: [], skipped_levels: [] } if plan.no_op?

        skipped_levels = authorization.reject { |entry| entry.fetch("allowed", false) }
        applied = applyable_changes
        return { applied_changes: [], skipped_levels: skipped_levels } if applied.empty?

        context.project.class.transaction do
          applied.each do |change|
            Settings.write(context, change.key, change.to)
          end

          save_changed_records!
          record_activity!(applied)
        end

        {
          applied_changes: applied.map { |change| result_for(change) },
          skipped_levels:
        }
      end

      private

      attr_reader :plan, :project, :actor

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

      def save_changed_records!
        [ context.project, context.user_setting, context.tenant_setting ].compact.uniq.each do |record|
          next unless record.changed?

          record.save!
        end
      end

      def record_activity!(applied)
        Accounts::RecordActivity.call(
          account: project.account,
          actor: actor,
          action: "project.settings_changed",
          subject: project,
          metadata: {
            profile: plan.profile_name,
            changed_fields: applied.map(&:key),
            skipped_levels: skipped_levels,
            changes: applied.map { |change| { "key" => change.key, "from" => change.from, "to" => change.to, "level" => change.level.to_s } }
          }
        )
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
