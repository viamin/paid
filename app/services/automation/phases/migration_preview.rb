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
        :label_enabled_capabilities, :label_enabled_work, :label_enabled_work_status, :active_grants, keyword_init: true) do
        def to_h
          {
            project_id: project.id,
            derived_settings: derived_settings,
            configured_settings: configured_settings,
            inbox_entries_leaving_default: disabled_phase_entries,
            label_enabled_capabilities: label_enabled_capabilities,
            label_enabled_work: label_enabled_work,
            label_enabled_work_status: label_enabled_work_status,
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

      # Provenance replays (outbound GitHub issue-events requests) one preview
      # render may perform. Each labeled record costs a request, so an
      # unbounded scan over a project's label history could exhaust the hourly
      # rate limit mid-render — the same exposure the candidate-scan bound in
      # Automation::FeatureActivation guards. Past the bound the preview is
      # reported as truncated rather than complete.
      PROVENANCE_REPLAY_LIMIT = 25

      LabelEnabledWork = Struct.new(:items, :status, keyword_init: true)

      # Bounds the provenance replays of one preview render: hands out at most
      # the remaining replays' worth of globally newest, unique work-item
      # candidates and remembers whether the labeled scope extended past it.
      class ProvenanceBudget
        def initialize(limit)
          @remaining = limit
          @truncated = false
        end

        def truncated?
          @truncated
        end

        # Fetches one row past the remaining budget to detect truncation, then
        # returns only the rows the budget still covers so each returned
        # record costs exactly one replay.
        def bound(scope)
          candidates = scope.limit(@remaining + 1).to_a
          @truncated ||= candidates.size > @remaining
          checked = candidates.take(@remaining)
          @remaining -= checked.size
          checked
        end
      end
      private_constant :ProvenanceBudget

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
        label_enabled_work_preview = label_enabled_work(settings.to_settings)

        Preview.new(
          project: project,
          derived_settings:,
          configured_settings: settings.to_settings,
          disabled_phase_entries: disabled_phase_entries(settings),
          label_enabled_work: label_enabled_work_preview.items,
          label_enabled_work_status: label_enabled_work_preview.status,
          label_enabled_capabilities: label_enabled_capabilities(label_enabled_work_preview.items),
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
      # work an activation would change. Provenance replays are bounded per
      # render (PROVENANCE_REPLAY_LIMIT); labeled work past the bound stays
      # unchecked and the preview reports truncation rather than completeness.
      # Phase settings retain subordinate controls while a phase is disabled.
      # Use their effective persisted map here because activation enforces that
      # map, not the capability-derived defaults shown elsewhere in the preview.
      def label_enabled_work(phase_settings)
        budget = ProvenanceBudget.new(PROVENANCE_REPLAY_LIMIT)
        provenance_available = true
        capabilities = disabled_label_capabilities(phase_settings)
        work_items = budget.bound(labeled_work_items(capabilities)).flat_map do |work_item|
          capabilities.filter_map do |capability|
            next unless label_activates_capability?(capability, work_item)

            trust = activation_label_trust(capability, work_item)
            provenance_available &&= trust != :unknown
            next unless trust == :trusted
            next unless currently_label_enabled?(capability, work_item)

            { capability:, phase: Automation::Phases.for_capability(capability), work_item_id: work_item.id }
          end
        end
        return LabelEnabledWork.new(items: [], status: "unavailable") unless provenance_available

        warn_truncated(budget)
        LabelEnabledWork.new(items: work_items, status: budget.truncated? ? "truncated" : "available")
      rescue GithubClient::RateLimitError => error
        Rails.logger.warn(
          message: "automation.phases.migration_preview.label_trust_rate_limited",
          project_id: project.id,
          error_class: error.class.name
        )
        LabelEnabledWork.new(items: [], status: "unavailable")
      end

      def warn_truncated(budget)
        return unless budget.truncated?

        Rails.logger.warn(
          message: "automation.phases.migration_preview.label_trust_truncated",
          project_id: project.id,
          provenance_replay_limit: PROVENANCE_REPLAY_LIMIT
        )
      end

      def phase_disabled_by_settings?(phase, phase_settings)
        !phase_settings.fetch(Automation::PhaseSettings::PHASES_KEY).fetch(phase, false)
      end

      def disabled_label_capabilities(phase_settings)
        LABEL_ACTIVATED_CAPABILITIES.select do |capability|
          phase_disabled_by_settings?(Automation::Phases.for_capability(capability), phase_settings)
        end
      end

      # Newest labeled work first across every relevant capability, so a
      # truncated preview keeps the most recent work regardless of its phase.
      def labeled_work_items(capabilities)
        capabilities.map { |capability| labeled_work_items_for(capability) }
          .reduce(project.issues.none) { |work_items, scope| work_items.or(scope) }
          .order(id: :desc)
      end

      def labeled_work_items_for(capability)
        scope = activation_labels(capability).reduce(project.issues.none) do |matching_work, label|
          matching_work.or(project.issues.where("labels @> ?", [ label ].to_json))
        end.where(github_state: "open")

        capability == "auto_merge" ? scope.pull_requests_only : scope.issues_only
      end

      def label_activates_capability?(capability, work_item)
        applicable_work_item = capability == "auto_merge" ? work_item.is_pull_request? : !work_item.is_pull_request?
        applicable_work_item && activation_labels(capability).any? { |label| work_item.has_label?(label) }
      end

      # A Paid-local activation is not evidence that a GitHub label was trusted.
      # Check the matching label separately because ignored-mode feature
      # evaluation intentionally short-circuits to the Paid-local state.
      def activation_label_trust(capability, work_item)
        trusts = activation_labels(capability).filter_map do |label|
          Automation::LabelPolicy.label_addition_trust(project, work_item, label) if work_item.has_label?(label)
        end
        return :trusted if trusts.include?(:trusted)
        return :unknown if trusts.include?(:unknown)

        :untrusted
      end

      def activation_labels(capability)
        labels = [ project.feature_activation_label_for(capability) ]
        labels << project.feature_activation_label_for("paid_in_full") unless capability == "auto_merge"
        labels.compact_blank
      end

      def currently_label_enabled?(capability, work_item)
        case capability
        when "auto_pick"
          Automation::FeatureActivation.issue_auto_pick_trigger(project:, issue: work_item).present?
        when "auto_enhance"
          Automation::FeatureActivation.issue_auto_pick_trigger(project:, issue: work_item).present? &&
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
