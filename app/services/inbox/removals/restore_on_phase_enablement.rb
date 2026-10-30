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
    # @spec INBOX-PHASE-RELEVANCE-007 @spec INBOX-PHASE-RELEVANCE-010 @spec OPERATOR-INBOX-023
    class RestoreOnPhaseEnablement
      def self.call(...)
        new(...).call
      end

      def initialize(project:, phases:, queue_user: nil)
        @project = project
        @phases = Array(phases).map(&:to_s)
        @queue_user = queue_user
      end

      def call
        return 0 if phases.empty?

        removals = scope.to_a
        return 0 if removals.empty?

        entries = reconciled_entries
        restored_count = removals.count do |removal|
          entry = entries[removal.request_key]
          next false unless still_actionable?(removal, entry)

          restore(removal, entry)
        end
        Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE) if restored_count.positive?
        restored_count
      end

      private

      attr_reader :phases, :project, :queue_user

      def scope
        InboxRemoval.active.where(project_id: project.id, responsible_phase: phases)
      end

      def reconciled_entries
        Inbox::Queue.new(user: project.created_by || queue_user, project:).entries.index_by(&:id)
      end

      def restore(removal, entry)
        return false unless removal.clear!

        HistoryRecorder.call(entry:, event_key: "inbox-restored:#{removal.id}:#{removal.cleared_at.to_f}",
          action: "Restored to Inbox", actor: "Paid", result: "completed", occurred_at: removal.cleared_at)
        true
      end

      def still_actionable?(removal, entry)
        return false unless entry
        return false unless Automation::PhaseSettings.phase_enabled?(project, removal.responsible_phase)

        entry.actionable? && removal.suppresses?(Inbox::RequestIdentity.occurrence_for(entry))
      end
    end
  end
end
