# frozen_string_literal: true

module Inbox
  module Removals
    # RDR-077 §5: a personal removal is suppressed until the project's
    # automation for the request's responsible phase transitions from disabled
    # to enabled. Saving an already-enabled phase is not a transition, and
    # phase enablement applies only to phase-owned requests.
    #
    # Restoration still runs through the same relevance policy, so a request
    # that is no longer actionable does not return.
    #
    # @spec INBOX-PHASE-RELEVANCE-007 @spec INBOX-PHASE-RELEVANCE-010
    class RestoreOnPhaseEnablement
      def self.call(...)
        new(...).call
      end

      def initialize(project:, phases:, user: nil)
        @project = project
        @phases = Array(phases).map(&:to_s)
        @user = user
      end

      def call
        return 0 if phases.empty?

        removals = scope.includes(:user).to_a
        return 0 if removals.empty?

        restored = 0
        removals.group_by(&:user).each do |removal_user, user_removals|
          entries = reconciled_entries(removal_user)
          user_removals.each do |removal|
            next unless still_actionable?(removal, entries[removal.request_key])

            removal.clear!
            restored += 1
          end
        end
        restored
      end

      private

      attr_reader :phases, :project, :user

      def scope
        removals = InboxRemoval.active.where(project_id: project.id, responsible_phase: phases)
        user ? removals.where(user:) : removals
      end

      def reconciled_entries(removal_user)
        Inbox::Queue.new(user: removal_user, project:).entries.index_by(&:id)
      end

      def still_actionable?(removal, entry)
        return false unless entry
        return false unless Automation::PhaseSettings.phase_enabled?(project, removal.responsible_phase)

        entry.actionable? && removal.suppresses?(Inbox::RequestIdentity.occurrence_for(entry))
      end
    end
  end
end
