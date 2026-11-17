# frozen_string_literal: true

module Automation
  class PhaseSettings
    # Shared, credential-free read model for the UI-adjacent API and MCP
    # surfaces. It deliberately reports stored controls even while the rollout
    # guard is off; inspection and rollback must never enable runtime work.
    # @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-008 @spec AUTOMATION-PHASES-014
    class Projection
      REVOCATION_NOTICE = "Revoking or ending a continuation grant does not disable independent project automation."

      def self.call(...) = new(...).call

      def initialize(project:)
        @project = project
      end

      def call
        {
          project_id: project.id,
          rollout_enabled: RolloutGuard.enabled?(project),
          settings: settings.to_h,
          configured: settings.configured?,
          derived_settings: settings.derive,
          phases: Automation::Phases::ALL.map { |phase| phase_payload(phase) },
          continuation_notice: REVOCATION_NOTICE,
          grants: project.work_item_continuation_grants.order(created_at: :desc).limit(50).map { |grant| grant_payload(grant) }
        }
      end

      def grant_payload(grant)
        {
          id: grant.id,
          issue_id: grant.issue_id,
          start_phase: grant.start_phase,
          endpoint: grant.endpoint,
          covered_phases: grant.covered_phases,
          active: grant.active?,
          completed_at: grant.completed_at,
          revoked_at: grant.revoked_at,
          notice: EffectivePolicyNotice.new(project:, phase: grant.start_phase, endpoint: grant.endpoint).selection_summary
        }
      end

      private

      attr_reader :project

      def settings
        @settings ||= PhaseSettings.call(project)
      end

      def phase_payload(phase)
        {
          id: phase,
          label: Automation::Phases.label(phase),
          enabled: settings.phase_enabled?(phase),
          responsibility: Automation::Phases::RESPONSIBILITIES.fetch(phase),
          release: phase == Automation::Phases::RELEASE_DEPLOYMENT ? settings.release_enabled? : nil,
          deployment: phase == Automation::Phases::RELEASE_DEPLOYMENT ? settings.deployment_enabled? : nil
        }.compact
      end
    end
  end
end
