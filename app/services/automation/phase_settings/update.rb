# frozen_string_literal: true

module Automation
  class PhaseSettings
    # Applies a phase-settings change and reports which phases actually
    # transitioned from disabled to enabled. Saving an already-enabled phase is
    # not a transition, so it never reconciles the Inbox.
    #
    # @spec AUTOMATION-PHASES-002 @spec INBOX-PHASE-RELEVANCE-004
    # @spec INBOX-PHASE-RELEVANCE-007
    class Update
      Result = Struct.new(:settings, :enabled_transitions, :project, keyword_init: true) do
        def enabled_transition?(phase)
          enabled_transitions.include?(phase.to_s)
        end
      end

      def self.call(...)
        new(...).call
      end

      def initialize(project:, params:, user: nil)
        @project = project
        @params = (params || {}).to_h
        @user = user
      end

      def call
        transitions = enabled_transitions

        project.update!(PhaseSettings::SETTINGS_KEY => sanitized)
        reconcile_removed_items(transitions)

        Result.new(settings: PhaseSettings.call(project), enabled_transitions: transitions, project:)
      end

      private

      attr_reader :params, :project, :user

      def enabled_transitions
        current.phases.select { |phase, was_enabled| !was_enabled && requested_phase(phase) }.keys
      end

      def reconcile_removed_items(transitions)
        return if transitions.empty?
        return unless Automation::RolloutGuard.enabled?(project)

        Inbox::Removals::RestoreOnPhaseEnablement.call(project:, phases: transitions, user:)
      end

      def current
        @current ||= PhaseSettings.call(project)
      end

      def requested_phases
        @requested_phases ||= params[PhaseSettings::PHASES_KEY].to_h.symbolize_keys
      end

      def requested_phase(phase)
        requested_phases[phase.to_sym]
      end

      # Only known phases are persisted, so an unknown key can never widen or
      # narrow authorization by accident.
      def sanitized
        {
          PhaseSettings::PHASES_KEY => Automation::Phases::ALL.index_with do |phase|
            requested_phase(phase) ? true : false
          end,
          PhaseSettings::RELEASE_KEY => requested_boolean(PhaseSettings::RELEASE_KEY, current.release_enabled?),
          PhaseSettings::DEPLOYMENT_KEY => requested_boolean(PhaseSettings::DEPLOYMENT_KEY, current.deployment_enabled?)
        }
      end

      def requested_boolean(key, fallback)
        value = params[key]
        return fallback if value.nil?

        ActiveModel::Type::Boolean.new.cast(value)
      end
    end
  end
end