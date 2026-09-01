# frozen_string_literal: true

module Projects
  # Ensures that every Paid-owned and built-in control label exists on the
  # connected GitHub repository, creating missing labels and reconciling the
  # color/description of any that already exist but have drifted from the
  # canonical definition. This is the single provisioning contract for every
  # GitHub label with a Paid behavioral consequence — see
  # docs/intent/github-label-provisioning/ for the full inventory and design.
  #
  # @spec GH-LABELS-001 @spec GH-LABELS-002 @spec GH-LABELS-004 @spec GH-LABELS-007 @spec GH-LABELS-008
  #
  # Each definition in {LABEL_DEFINITIONS} carries a `kind` that distinguishes
  # three categories of GitHub label (@spec GH-LABELS-003):
  # - `:control`      — applying or removing the label changes automation.
  # - `:status`       — applied by Paid as an output/status marker.
  # - `:informational` — descriptive taxonomy with no automation effect.
  #
  # Standard labels include:
  # - generated_label_name  (e.g. "paid-generated")
  # - automation_label_name (e.g. "paid-automation")
  # - enhance_issue_needs_input_label_name (e.g. "paid-needs-input")
  # - enhance_issue_enhanced_label_name    (e.g. "paid-enhanced")
  # - recommend_close                      (e.g. "paid-recommend-close"; overridable via
  #                                        Project#label_for_stage("recommend_close"))
  # - needs_input                          (defaults to the same name as
  #                                        enhance_issue_needs_input_label_name; overridable
  #                                        via Project#label_for_stage("needs_input"))
  # - paused, escalated, dismiss_escalation, skip_auto_merge, auto_merged,
  #   auto_merged_dependabot, auto_released, paid_ready, model_health (hard-coded, literal names)
  # - tdd test-review labels (RDR-056):
  #   * tests_ready_for_review             (paid-tests-ready-for-review)
  #   * tests_approved                     (paid-tests-approved)
  #   * test_changes_requested             (paid-test-changes-requested)
  # - Priority labels          (P1, P2, P3 by default)
  # - The project's effective auto-pick skip labels (planning/research/waiting/
  #   tracking/epic/needs-manual-setup by default; project/tenant/user overridable)
  #
  # Only labels in this canonical set are ever created or modified — any other
  # repository label (user-owned taxonomy, third-party bot labels, etc.) is
  # left untouched.
  #
  # @example
  #   result = Projects::EnsureStandardLabels.call(project: project)
  #   result.created    # => ["paid-generated", "P1"]
  #   result.existing   # => ["paid-automation"]
  #   result.reconciled # => [{ name: "P2", fields: ["color"] }]
  #   result.errors     # => []
  class EnsureStandardLabels
    LABEL_DEFINITIONS = {
      generated: { color: "0e8a16", description: "Created by Paid", kind: :status },
      automation: { color: "1d76db", description: "Triggers Paid automation for this issue; remove to opt out.", kind: :control },
      enhance_issue_needs_input: { color: "d876e3", description: "Paid needs answers before enhancing this issue again", kind: :status },
      enhance_issue_enhanced: { color: "0e8a16", description: "Paid has added implementation context to this issue", kind: :status },
      recommend_close: { color: "fbca04", description: "Paid ran but produced no PR — human review needed", kind: :status },
      paused: { color: "5319e7", description: "Pauses Paid automation on this issue; remove to resume.", kind: :control },
      escalated: { color: "b60205", description: "Applied by Paid to pause automation for human review; remove to resume.", kind: :control },
      dismiss_escalation: { color: "c2e0c6", description: "Alternate escalation-dismissed marker; cleared automatically by Paid.", kind: :status },
      skip_auto_merge: { color: "e99695", description: "Blocks Paid from automatically merging this pull request.", kind: :control },
      auto_merged: { color: "0e8a16", description: "Applied by Paid after automatically merging this pull request.", kind: :status },
      auto_merged_dependabot: { color: "0e8a16", description: "Applied by Paid after automatically merging this Dependabot pull request.", kind: :status },
      auto_released: { color: "0e8a16", description: "Applied by Paid after automatically merging this release pull request.", kind: :status },
      paid_ready: { color: "0e8a16", description: "Applied by Paid when a pull request is marked ready for review.", kind: :status },
      model_health: { color: "5319e7", description: "Flags provider model drift or broken runner models. Informational only.", kind: :informational },
      tdd_test_review: {
        name: "paid-tests-ready-for-review",
        color: "fbca04",
        description: "Tests are ready for review; implementation is blocked until approved.",
        kind: :control
      },
      tdd_tests_approved: {
        name: "paid-tests-approved",
        color: "0e8a16",
        description: "Tests approved — Paid may begin implementation.",
        kind: :status
      },
      tdd_test_changes_requested: {
        name: "paid-test-changes-requested",
        color: "d93f0b",
        description: "Test changes requested; implementation is blocked until resolved.",
        kind: :control
      },
      priority: {
        "P1" => { color: "d93f0b", description: "High priority", kind: :informational },
        "P2" => { color: "ff9800", description: "Medium priority", kind: :informational },
        "P3" => { color: "fbca04", description: "Low priority", kind: :informational }
      }
    }.freeze

    # Auto-pick skip labels are configurable per project/tenant/user
    # (Project#effective_auto_pick_skip_labels), so they are keyed by label
    # name rather than a fixed symbol. Names matching AutoPickSkipLabels::DEFAULTS
    # get a specific consequence description; any project-custom name falls
    # back to the generic one.
    AUTO_PICK_SKIP_LABEL_COLOR = "bfd4f2"
    AUTO_PICK_SKIP_LABEL_DESCRIPTIONS = {
      "planning" => "Excludes this issue from Paid auto-pick while planning is in progress.",
      "research" => "Excludes this issue from Paid auto-pick while research is in progress.",
      "waiting" => "Excludes this issue from Paid auto-pick while it waits on something else.",
      "tracking" => "Excludes this issue from Paid auto-pick; tracking/meta issue, not actionable.",
      "epic" => "Excludes this issue from Paid auto-pick; epic/parent issue, not directly actionable.",
      "needs-manual-setup" => "Excludes this issue from Paid auto-pick until manual setup is completed."
    }.freeze
    AUTO_PICK_SKIP_LABEL_DEFAULT_DESCRIPTION = "Excludes this issue from Paid auto-pick while applied."

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    # Best-effort variant for runtime write paths that apply a single status
    # label (paid-ready, paid-auto-merged, paid-auto-merged-dependabot,
    # paid-auto-released) after their primary action already succeeded. A
    # labels-list failure (e.g. insufficient permissions) must not fail the
    # calling job/activity — it already logs its own warning when the
    # subsequent label write 404s, so this only exists to make that write
    # succeed on a repo that never went through manual sync or the
    # create-time bootstrap (@spec GH-LABELS-001).
    def self.call_best_effort(project:, logger: Rails.logger)
      call(project: project)
    rescue GithubClient::Error => e
      logger.warn(
        message: "github_sync.ensure_standard_labels_best_effort_failed",
        project_id: project.id,
        error: e.message
      )
      nil
    end

    def call
      client = github_client
      repo = project.full_name

      expected = expected_labels

      # Detect cross-category name collisions before any GitHub call.
      # Processing the same GitHub label twice would let the later
      # definition's reconcile_divergence silently PATCH the shared label
      # into whichever color/description ran last, masking a project
      # misconfiguration as success (@spec GH-LABELS-007).
      colliding_names = detect_label_collisions(expected)

      remote_labels = fetch_remote_labels(client, repo)
      remote_by_name = remote_labels.each_with_object({}) do |label, h|
        h[label.name.downcase] = label
      end

      created = []
      existing = []
      reconciled = []
      errors = colliding_names.flat_map { |c| c[:errors] }

      expected.each do |expected|
        next if colliding_names.any? { |c| c[:name].casecmp?(expected[:name]) }

        remote = remote_by_name[expected[:name].downcase]

        if remote.nil?
          create_label(client, repo, expected, created, existing, errors)
        else
          existing << expected[:name]
          reconcile_divergence(client, repo, remote, expected, reconciled, errors)
        end
      end

      log_result(created, existing, reconciled, errors)

      Result.new(created: created, existing: existing, reconciled: reconciled, errors: errors)
    end

    private

    def github_client
      return project.client if project.respond_to?(:client)

      project.github_token.client
    end

    def expected_labels
      [
        *configurable_labels,
        *recommend_close_label,
        *needs_input_stage_label,
        *fixed_control_labels,
        *tdd_labels,
        *auto_pick_skip_label_definitions,
        *priority_label_definitions
      ]
    end

    # Each entry returned from the builders below carries the category
    # identifier it was resolved from, so {detect_label_collisions} can
    # produce an actionable error that names both claims on a colliding
    # label rather than a generic "duplicate" message.
    def label_entry(name, key, category:)
      definition = LABEL_DEFINITIONS.fetch(key)
      { name: name, color: definition[:color], description: definition[:description], category: category }
    end

    def configurable_labels
      [
        label_entry(project.generated_label_name, :generated, category: "generated_label_name"),
        label_entry(project.automation_label_name, :automation, category: "automation_label_name"),
        label_entry(project.enhance_issue_needs_input_label_name, :enhance_issue_needs_input,
          category: "enhance_issue_needs_input_label_name"),
        label_entry(project.enhance_issue_enhanced_label_name, :enhance_issue_enhanced,
          category: "enhance_issue_enhanced_label_name")
      ]
    end

    # No dedicated column for the recommend_close label; the runtime
    # resolves it via Project#label_for_stage with a constant fallback,
    # so mirror that resolution here.
    def recommend_close_label
      name = project.label_for_stage("recommend_close") ||
        Activities::HandleNoOutputIssueRunActivity::PAID_RECOMMEND_CLOSE_LABEL
      [ label_entry(name, :recommend_close, category: "recommend_close_label_mapping") ]
    end

    # HandleNoOutputIssueRunActivity#add_needs_input_label resolves the
    # needs-input label the same way (label_for_stage with a literal
    # fallback) rather than through enhance_issue_needs_input_label_name, so
    # the two are independently configurable even though their defaults
    # coincide (FetchIssuesActivity#repair_questionless_needs_input already
    # treats them as distinct sources to repair). Skip re-adding the entry
    # when it resolves to the name already covered by configurable_labels'
    # enhance_issue_needs_input entry, so an unconfigured project's shared
    # default doesn't trip the cross-category collision guard.
    def needs_input_stage_label
      name = project.label_for_stage("needs_input") ||
        Activities::HandleNoOutputIssueRunActivity::PAID_NEEDS_INPUT_LABEL
      return [] if name.casecmp?(project.enhance_issue_needs_input_label_name)

      [ label_entry(name, :enhance_issue_needs_input, category: "needs_input_label_mapping") ]
    end

    # Hard-coded control/status labels (@spec GH-LABELS-006 for escalation).
    # Names are deliberately literal and not configurable per-project — each
    # is defined once on its owning class/model and referenced here so this
    # is the single place their color/description are declared.
    def fixed_control_labels
      [
        label_entry(Issue::PAUSED_LABEL, :paused, category: "Issue::PAUSED_LABEL"),
        label_entry(Issue::ESCALATED_LABEL, :escalated, category: "Issue::ESCALATED_LABEL"),
        label_entry(Issue::DISMISS_ESCALATION_LABEL, :dismiss_escalation,
          category: "Issue::DISMISS_ESCALATION_LABEL"),
        label_entry(Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL, :skip_auto_merge,
          category: "Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL"),
        label_entry(Activities::MergePullRequestActivity::PAID_AUTO_MERGED_LABEL, :auto_merged,
          category: "Activities::MergePullRequestActivity::PAID_AUTO_MERGED_LABEL"),
        label_entry(DependabotAutoMergeJob::PAID_AUTO_MERGED_LABEL, :auto_merged_dependabot,
          category: "DependabotAutoMergeJob::PAID_AUTO_MERGED_LABEL"),
        label_entry(AutoReleaseEvaluationJob::PAID_AUTO_RELEASED_LABEL, :auto_released,
          category: "AutoReleaseEvaluationJob::PAID_AUTO_RELEASED_LABEL"),
        label_entry(Activities::MarkPrReadyActivity::PAID_READY_LABEL, :paid_ready,
          category: "Activities::MarkPrReadyActivity::PAID_READY_LABEL"),
        label_entry(Models::FileModelHealthIssue::LABEL, :model_health,
          category: "Models::FileModelHealthIssue::LABEL")
      ]
    end

    # TDD test-review labels (RDR-056). Names are deliberately literal and
    # not configurable per-project — Paid's queue and label-gate logic
    # matches on these exact strings.
    def tdd_labels
      %i[tdd_test_review tdd_tests_approved tdd_test_changes_requested].map do |key|
        definition = LABEL_DEFINITIONS.fetch(key)
        { name: definition[:name], color: definition[:color], description: definition[:description],
          category: "TDD test-review label: #{definition[:name]}" }
      end
    end

    # Built-in auto-pick skip labels (planning/research/waiting/tracking/epic/
    # needs-manual-setup by default). These are recognized regardless of who
    # applies them, so they are provisioned with a description that states
    # the auto-pick consequence rather than left as undocumented taxonomy.
    def auto_pick_skip_label_definitions
      project.effective_auto_pick_skip_labels.map do |name|
        {
          name: name,
          color: AUTO_PICK_SKIP_LABEL_COLOR,
          description: AUTO_PICK_SKIP_LABEL_DESCRIPTIONS[name] || AUTO_PICK_SKIP_LABEL_DEFAULT_DESCRIPTION,
          category: "auto_pick_skip_label"
        }
      end
    end

    def priority_label_definitions
      project.effective_priority_labels.map do |tier, label_name|
        defaults = LABEL_DEFINITIONS[:priority][tier] || {}
        {
          name: label_name,
          color: defaults[:color] || "ededed",
          description: defaults[:description] || "Priority #{tier}",
          category: "priority_label[#{tier}]"
        }
      end
    end

    # Returns one collision entry per colliding name: {name:, errors:},
    # where errors is a single {name:, error:} describing every category
    # that claims the label so the user can rename the misconfigured one.
    def detect_label_collisions(expected)
      expected.group_by { |entry| entry[:name].downcase }
        .select { |_, entries| entries.size > 1 }
        .map do |_normalized_name, entries|
          winner_name = entries.first[:name]
          categories = entries.map { |entry| entry[:category] }
          {
            name: winner_name,
            errors: [ { name: winner_name, error: label_collision_error_message(winner_name, categories) } ]
          }
        end
    end

    def label_collision_error_message(name, categories)
      "Multiple Paid-owned categories claim the label '#{name}': #{categories.join(', ')}. " \
        "Rename one of the configured labels so each canonical label has a unique name."
    end

    def fetch_remote_labels(client, repo)
      client.labels(repo)
    rescue GithubClient::ApiError => e
      if e.status == 403
        raise GithubClient::ApiError.new(
          "Insufficient permissions to read labels. Ensure the GitHub token has repo scope.",
          status: 403
        )
      end
      raise
    end

    # Creates a missing canonical label. A 422 is treated as a lost create
    # race only when a follow-up fetch confirms the label now exists —
    # GitHub also returns 422 for real validation failures (invalid name,
    # description past the 100-character limit), which must surface in
    # `errors` so callers never proceed without the control label
    # (@spec GH-LABELS-008).
    def create_label(client, repo, expected, created, existing, errors)
      client.create_label(repo, name: expected[:name], color: expected[:color], description: expected[:description])
      created << expected[:name]
    rescue GithubClient::ApiError => e
      if e.status == 422 && fetch_label(client, repo, expected[:name])
        existing << expected[:name]
      else
        errors << { name: expected[:name], error: permission_aware_message(e, "create") }
      end
    end

    # Returns the remote label when it exists, nil when it does not or the
    # verification call itself fails — an unverifiable 422 is never a race
    # win (@spec GH-LABELS-008).
    def fetch_label(client, repo, name)
      client.label(repo, name)
    rescue GithubClient::NotFoundError, GithubClient::ApiError
      nil
    end

    # Reconciles (rather than only reports) any color/description drift on an
    # existing Paid-owned label, so stale descriptions never persist past the
    # next sync (@spec GH-LABELS-002).
    def reconcile_divergence(client, repo, remote, expected, reconciled, errors)
      fields = divergent_fields(remote, expected)
      return if fields.empty?

      client.update_label(repo, remote.name, color: expected[:color], description: expected[:description])
      reconciled << { name: expected[:name], fields: fields }
    rescue GithubClient::NotFoundError
      # Another writer deleted the label between our list and update calls.
      # Record the loss rather than abort the remaining labels' sync; the
      # next sync re-creates it.
      errors << {
        name: expected[:name],
        error: "Label '#{expected[:name]}' was deleted during the sync; retry the sync to re-create it."
      }
    rescue GithubClient::ApiError => e
      errors << { name: expected[:name], error: permission_aware_message(e, "update") }
    end

    def divergent_fields(remote, expected)
      fields = []

      remote_color = remote.color.to_s.delete_prefix("#").downcase
      expected_color = expected[:color].to_s.delete_prefix("#").downcase
      fields << "color" if remote_color != expected_color

      remote_desc = remote.respond_to?(:description) ? remote.description.to_s : ""
      fields << "description" if expected[:description].present? && remote_desc != expected[:description]

      fields
    end

    def permission_aware_message(error, action)
      return "Insufficient permissions to #{action} labels. Ensure the GitHub token has repo scope." if error.status == 403

      error.message
    end

    def log_result(created, existing, reconciled, errors)
      Rails.logger.info(
        message: "github_sync.ensure_standard_labels",
        project_id: project.id,
        repo: project.full_name,
        created: created,
        existing: existing,
        reconciled_count: reconciled.size,
        error_count: errors.size
      )
    end

    # Result object returned by EnsureStandardLabels.
    class Result
      attr_reader :created, :existing, :reconciled, :errors

      def initialize(created:, existing:, reconciled:, errors:)
        @created = created
        @existing = existing
        @reconciled = reconciled
        @errors = errors
      end

      def notice_message
        parts = []
        parts << "Created labels: #{created.join(', ')}." if created.any?
        parts << "#{existing.size} label(s) already present." if existing.any?
        if reconciled.any?
          names = reconciled.map { |r| r[:name] }.uniq
          parts << "Reconciled labels: #{names.join(', ')}."
        end
        if errors.any?
          names = errors.map { |e| e[:name] }
          parts << "Failed to sync: #{names.join(', ')}."
        end
        parts.join(" ").presence || "All standard labels are up to date."
      end

      def any_errors?
        errors.any?
      end
    end
  end
end
