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
        :label_enabled_capabilities, :label_enabled_work, :active_grants, keyword_init: true) do
        def to_h
          {
            project_id: project.id,
            derived_settings: derived_settings,
            configured_settings: configured_settings,
            inbox_entries_leaving_default: disabled_phase_entries,
            label_enabled_capabilities: label_enabled_capabilities,
            label_enabled_work: label_enabled_work,
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
        derived_settings = settings.derive
        label_enabled_work = label_enabled_work(derived_settings)

        Preview.new(
          project: project,
          derived_settings:,
          configured_settings: settings.to_settings,
          disabled_phase_entries: disabled_phase_entries(settings),
          label_enabled_work:,
          label_enabled_capabilities: label_enabled_capabilities(label_enabled_work),
          active_grants: active_grants
        )
      end

      private

      attr_reader :project, :user

      # Requests that would leave the default Inbox under the derived defaults.
      # Built from the Disabled phases view so the preview reports exactly what
      # an operator would see after activation.
      def disabled_phase_entries(settings)
        derived_settings = settings.derive
        Inbox::Queue
          .new(user:, project:)
          .entries
          .select { |entry| disabled_by_derived_settings?(entry, derived_settings) }
          .filter_map { |entry| entry_identity(entry) }
      end

      def disabled_by_derived_settings?(entry, derived_settings)
        ownership = entry.phase_ownership
        ownership.phase_owned? && !derived_settings.fetch(Automation::PhaseSettings::PHASES_KEY)
          .fetch(ownership.responsible_phase, false)
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

      def label_enabled_capabilities(work_items)
        work_items.map { |work| work.slice(:capability, :phase) }
          .uniq
      end

      # Preview the individual work items that trusted labels currently admit.
      # A label's presence alone is insufficient: execution checks its trusted
      # event provenance, so the preview uses that same decision before naming
      # work an activation would change.
      def label_enabled_work(derived_settings)
        LABEL_ACTIVATED_CAPABILITIES.flat_map do |capability|
          phase = Automation::Phases.for_capability(capability)
          next [] unless phase_disabled_by_derived_settings?(phase, derived_settings)

          labeled_work_items(capability).filter_map do |work_item|
            next unless currently_label_enabled?(capability, work_item)

            { capability:, phase:, work_item_id: work_item.id }
          end
        end
      end

      def phase_disabled_by_derived_settings?(phase, derived_settings)
        !derived_settings.fetch(Automation::PhaseSettings::PHASES_KEY).fetch(phase, false)
      end

      def labeled_work_items(capability)
        labels = [ project.feature_activation_label_for(capability) ]
        labels << project.feature_activation_label_for("paid_in_full") unless capability == "auto_merge"
        scope = labels.compact_blank.reduce(project.issues.none) do |matching_work, label|
          matching_work.or(project.issues.where("labels @> ?", [ label ].to_json))
        end.where(github_state: "open")

        capability == "auto_merge" ? scope.pull_requests_only : scope.issues_only
      end

      def currently_label_enabled?(capability, work_item)
        case capability
        when "auto_pick"
          Automation::FeatureActivation.issue_auto_pick_trigger(project:, issue: work_item).present?
        when "auto_enhance"
          Automation::FeatureActivation.issue_auto_enhance_enabled?(project:, issue: work_item)
        when "auto_merge"
          Automation::FeatureActivation.pull_request_feature_enabled?(project:, pull_request: work_item, feature: capability)
        end
      end

      # Existing manual runs acquire no continuation grant retroactively; this
      # is reported so operators can see what a rollback would have to absorb.
      def active_grants
        WorkItemContinuationGrant.active.where(project_id: project.id).count
      end
    end
  end
end
