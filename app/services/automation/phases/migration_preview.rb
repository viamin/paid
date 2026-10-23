# frozen_string_literal: true

module Automation
  module Phases
    # RDR-077 migration step: derive phase defaults from a project's currently
    # effective capabilities and report what activation would change, before
    # anything is switched on.
    #
    # Read-only by construction: it enables nothing, grants nothing, and never
    # grants continuation authorization retroactively to existing manual runs.
    #
    # @spec AUTOMATION-PHASES-015
    class MigrationPreview
      Preview = Struct.new(:project, :derived_settings, :configured_settings, :disabled_phase_entries,
        :label_enabled_capabilities, :active_grants, keyword_init: true) do
        def to_h
          {
            project_id: project.id,
            derived_settings: derived_settings,
            configured_settings: configured_settings,
            inbox_entries_leaving_default: disabled_phase_entries,
            label_enabled_capabilities: label_enabled_capabilities,
            active_grants: active_grants
          }
        end

        def inbox_changes_count
          disabled_phase_entries.size
        end
      end

      # Capabilities a trusted per-item activation label can turn on outside the
      # project setting.
      LABEL_ACTIVATED_CAPABILITIES = %w[auto_pick auto_enhance auto_merge].freeze

      def self.call(...)
        new(...).call
      end

      def initialize(project:, user:)
        @project = project
        @user = user
      end

      def call
        settings = Automation::PhaseSettings.call(project)

        Preview.new(
          project: project,
          derived_settings: settings.derive,
          configured_settings: settings.to_settings,
          disabled_phase_entries: disabled_phase_entries(settings),
          label_enabled_capabilities: label_enabled_capabilities(settings),
          active_grants: active_grants
        )
      end

      private

      attr_reader :project, :user

      # Requests that would leave the default Inbox under the derived defaults.
      # Built from the Disabled phases view so the preview reports exactly what
      # an operator would see after activation.
      def disabled_phase_entries(settings)
        return [] unless Automation::RolloutGuard.enabled?(project)

        Inbox::Queue
          .call(user:, project:, scope: Inbox::Queue::DISABLED_PHASES_SCOPE)
          .filter_map { |entry| entry_identity(entry) }
      end

      def entry_identity(entry)
        ownership = entry.phase_ownership
        return nil unless ownership.phase_owned?

        {
          request_key: entry.id,
          kind: entry.kind,
          responsible_phase: ownership.responsible_phase,
          stop_reason: entry.stop_reason
        }
      end

      # Currently label-enabled work that would lose automatic execution when
      # its phase is disabled by the derived defaults.
      def label_enabled_capabilities(settings)
        LABEL_ACTIVATED_CAPABILITIES.filter_map do |capability|
          phase = Automation::Phases.for_capability(capability)
          next if phase.nil?
          next if settings.phase_enabled?(phase)
          next unless label_enabled?(capability)

          { capability: capability, phase: phase }
        end
      end

      # Label presence is the preview's proxy for "work a trusted label would
      # currently activate": a label on an open item is exactly the signal
      # Automation::FeatureActivation reads, without making a GitHub API call.
      def label_enabled?(capability)
        label = project.feature_activation_label_for(capability)
        return false if label.blank?

        scope = project.issues.where(github_state: "open").where("labels @> ?", [ label ].to_json)
        capability == "auto_merge" ? scope.pull_requests_only.exists? : scope.issues_only.exists?
      end

      # Existing manual runs acquire no continuation grant retroactively; this
      # is reported so operators can see what a rollback would have to absorb.
      def active_grants
        WorkItemContinuationGrant.active.where(project_id: project.id).count
      end
    end
  end
end