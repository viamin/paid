# frozen_string_literal: true

module Configuration
  module Profiles
    # Raised by {Applier} when the plan has unmet prerequisites.
    class BlockedError < StandardError; end
    # Raised by {Applier} when the actor is not authorized at a needed level.
    class UnauthorizedError < StandardError; end

    # Applies a {Plan} to a {Project} transactionally and idempotently.
    #
    # Guarantees (RDR-044):
    # - +transactional+: all writes (project save + activity record) succeed or
    #   all roll back.
    # - +idempotent+: re-applying a plan whose targets already hold is a no-op
    #   (no save, no activity, empty result).
    # - +per-level authorized+: each distinct change level is authorized via
    #   its policy before any write. Today only +:project+ exists.
    # - +returns per-change results+: one hash per applied change
    #   (<tt>{ key:, from:, to:, applied: true }</tt>).
    # - +records activity+ once per apply via {Accounts::RecordActivity}.
    class Applier
      LEVEL_POLICIES = {
        project: { policy_class: ProjectPolicy, query: :update? }
      }.freeze

      def self.call(...) = new(...).call

      def initialize(plan:, project:, actor:)
        @plan = plan
        @project = project
        @actor = actor
      end

      def call
        raise BlockedError, block_message if plan.blocked?
        return [] if plan.no_op?

        authorize!

        applied = []
        Project.transaction do
          plan.changes.each do |change|
            descriptor = Settings.fetch(change.key)
            next if descriptor.read.call(project) == change.to

            descriptor.write.call(project, change.to)
            applied << change
          end

          next unless applied.any?

          project.save!
          record_activity!(applied)
        end

        applied.map { |change| result_for(change) }
      end

      private

      attr_reader :plan, :project, :actor

      def authorize!
        levels.each do |level|
          config = LEVEL_POLICIES.fetch(level)
          policy = config.fetch(:policy_class).new(actor, project)
          next if policy.public_send(config.fetch(:query))

          raise UnauthorizedError, "Not authorized to apply #{level}-level configuration changes"
        end
      end

      def levels
        plan.changes.filter_map { |change| Settings.fetch(change.key).level }.uniq
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
            changes: applied.map { |change| { "key" => change.key, "from" => change.from, "to" => change.to } }
          }
        )
      end

      def result_for(change)
        { key: change.key, from: change.from, to: change.to, applied: true }
      end

      def block_message
        "Cannot apply profile #{plan.profile_name.inspect}: unmet prerequisites: #{plan.unmet_prerequisites.join(', ')}"
      end
    end
  end
end
