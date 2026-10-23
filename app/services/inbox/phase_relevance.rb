# frozen_string_literal: true

# RDR-077 §5: which phase-owned Inbox requests are actionable under current
# project policy and continuation grants.
#
# A request is relevant when its phase is enabled, when an active continuation
# grant covers that phase and work, or when it is needed to complete an
# outstanding explicitly started manual action. Requests with no project phase
# (platform health, credential, safety, and unclassified legacy requests) stay
# relevant: ambiguity must never silently hide work or imply execution
# authority.
#
# Personal suppression is layered separately by Inbox::Removals::Suppression.
#
# @spec INBOX-PHASE-RELEVANCE-002 @spec INBOX-PHASE-RELEVANCE-003
# @spec INBOX-PHASE-RELEVANCE-010
module Inbox
  class PhaseRelevance
    ACTIONABLE = :actionable
    DISABLED_PHASE = :disabled_phase

    Result = Struct.new(:state, :ownership, :reason, :recovery, keyword_init: true) do
      def actionable?
        state == ACTIONABLE
      end

      def disabled_phase?
        state == DISABLED_PHASE
      end

      def stop_reason
        reason if disabled_phase?
      end
    end

    def self.call(...)
      new(...).call
    end

    def self.for_entries(entries, governed_project_ids: nil)
      context = Context.new(entries:, governed_project_ids:)
      entries.index_by(&:id).transform_values { |entry| new(context:).call(entry) }
    end

    def initialize(context: nil)
      @context = context
    end

    def call(entry)
      ownership = entry.phase_ownership
      return Result.new(state: ACTIONABLE, ownership:) unless governed?(ownership)
      return Result.new(state: ACTIONABLE, ownership:) if relevant?(entry, ownership)

      disabled(ownership)
    end

    private

    attr_reader :context

    # Relevance only applies to a project whose phase model is enabled.
    def governed?(ownership)
      return false unless ownership.project

      context ? context.governed?(ownership) : Automation::RolloutGuard.enabled?(ownership.project)
    end

    def relevant?(entry, ownership)
      return true unless ownership.phase_owned?

      phase_enabled?(ownership) || grant_covers?(entry, ownership) || outstanding_manual_action?(entry, ownership)
    end

    def phase_enabled?(ownership)
      Automation::PhaseSettings.phase_enabled?(ownership.project, ownership.responsible_phase)
    end

    def grant_covers?(entry, ownership)
      return context.grant_covers?(entry, ownership) if context

      Automation::ContinuationGrantLookup
        .covering(project: ownership.project, phase: ownership.responsible_phase, work_item: work_item_for(entry))
        .present?
    end

    def outstanding_manual_action?(entry, ownership)
      issue = entry.issue
      return false unless issue
      return context.outstanding_manual_action?(entry, ownership) if context

      Automation::ContinuationGrantLookup.outstanding_manual_action?(project: ownership.project, issue:)
    end

    def work_item_for(entry)
      entry.issue || (entry.record if entry.record.is_a?(Issue))
    end

    def disabled(ownership)
      Result.new(
        state: DISABLED_PHASE,
        ownership:,
        reason: "#{Automation::Phases.label(ownership.responsible_phase)} automation is disabled for this project.",
        recovery: "Enable the #{Automation::Phases.label(ownership.responsible_phase)} phase in project settings, " \
                  "start this work manually, or grant automatic continuation for it."
      )
    end
  end
end
