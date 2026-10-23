# frozen_string_literal: true

module Automation
  module FeatureActivation
    module_function

    # RDR-077: every capability entry point asks the one effective policy
    # first. A disabled phase grants no standing authorization, so a trusted
    # per-item activation label (or catch-all label) cannot re-enable it —
    # while a continuation grant for the covered work still authorizes the
    # action. While the rollout flag is off this is always permitted, so the
    # pre-existing behavior is untouched.
    #
    # @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-007
    def phase_authorized?(project:, capability:, work_item: nil)
      phase = Automation::Phases.for_capability(capability)
      return true if phase.nil?

      Automation::EffectivePolicy.call(project:, phase:, work_item:, trigger: :automatic).permitted?
    end

    # @spec AUTOMATION-ACTIVATION-003 @spec AUTOMATION-ACTIVATION-004 @spec AUTOMATION-ACTIVATION-005 @spec AUTOMATION-ACTIVATION-006
    # @spec LABEL-CONTROL-007 — In ignored mode the activation signal lives
    # on the Issue row (paid_activation_state = "activated") rather than on a
    # GitHub label; its caller uses the sentinel to take the authenticated
    # Paid-local authorization path without replaying label history.
    def issue_auto_pick_trigger(project:, issue:)
      return nil unless phase_authorized?(project:, capability: "auto_pick", work_item: issue)
      return paid_local_trigger(issue) if project.paid_local_activation?

      return nil if blocked_by_skip_labels?(project, issue)

      label = trusted_issue_specific_label(project, issue, "auto_pick")
      return label if label.present?

      trusted_issue_specific_label(project, issue, "paid_in_full")
    end

    # @spec LABEL-CONTROL-007 — In ignored mode there is no per-item
    # auto-enhance activation; auto-enhance follows the project-level
    # setting alone. The issue itself need only be paid-activated for the
    # underlying run to be queued, which is checked by the caller.
    def issue_auto_enhance_enabled?(project:, issue:)
      return false unless phase_authorized?(project:, capability: "auto_enhance", work_item: issue)
      return project.auto_enhance_enabled? if project.paid_local_activation?

      return true if project.auto_enhance_enabled?
      return false if blocked_by_skip_labels?(project, issue)

      trusted_issue_specific_label(project, issue, "auto_enhance").present? ||
        trusted_issue_specific_label(project, issue, "paid_in_full").present?
    end

    # @spec LABEL-CONTROL-007 — Ignored-mode TDD mode follows the project
    # setting alone; per-item TDD activation labels do not exist (#4253).
    def issue_tdd_mode(project:, issue:)
      if project.paid_local_activation?
        return project.tdd_mode if project.tdd_mode.in?(%w[strict non_strict])

        return "off"
      end

      return project.tdd_mode if project.tdd_mode.in?(%w[strict non_strict])
      return "off" unless issue
      return "off" if blocked_by_skip_labels?(project, issue)

      return "strict" if trusted_issue_specific_label(project, issue, "tdd_strict").present?
      return "non_strict" if trusted_issue_specific_label(project, issue, "tdd_auto").present?
      return "strict" if trusted_issue_specific_label(project, issue, "paid_in_full").present?

      "off"
    end

    # A per-PR activation label must never re-enable a PR-side feature that
    # upstream mode disables: acting on the upstream repository or on PRs
    # opened in it is not something a label added to a PR can authorize.
    # @spec UPSTREAM-GATE-002 @spec LABEL-CONTROL-007 — In ignored mode
    # there is no per-PR feature activation; PR features resolve to the
    # project-level setting alone.
    def pull_request_feature_enabled?(project:, pull_request:, feature:)
      return false unless phase_authorized?(project:, capability: feature, work_item: pull_request)
      return false if upstream_mode_disables?(project, feature)

      # @spec LABEL-CONTROL-007 — ignored mode has no per-PR feature
      # activation; the project-level setting is the only signal.
      return project_setting_enabled?(project, feature) if project.paid_local_activation?

      return true if project_setting_enabled?(project, feature)
      return false unless pull_request

      return true if trusted_pr_specific_label(project, pull_request, feature).present?

      return false if feature == "auto_merge"

      trusted_parent_issue_catchall_label(project, pull_request).present?
    end

    # Dependabot-only mode enables the dedicated Dependabot evaluator, never
    # the human pull-request merge path. A trusted per-PR activation label can
    # opt an individual human PR into that path while the project setting is
    # off, but cannot broaden Dependabot-only mode.
    # @spec AUTO-MERGE-008 INBOX-FOUNDATION-011 OPERATOR-INBOX-002K LABEL-CONTROL-007
    def human_pull_request_auto_merge_enabled?(project:, pull_request:)
      return false unless phase_authorized?(project:, capability: "auto_merge", work_item: pull_request)
      return false if upstream_mode_disables?(project, "auto_merge")
      return project.auto_merge_enabled? if project.paid_local_activation?
      return true if project.auto_merge_mode == "all"
      return false unless project.auto_merge_mode == "off"

      trusted_pr_specific_label(project, pull_request, "auto_merge").present?
    end

    # @spec LABEL-CONTROL-007
    def any_pull_request_feature_enabled?(project:, feature:)
      return false unless phase_authorized?(project:, capability: feature)
      return false if upstream_mode_disables?(project, feature)

      return true if project_setting_enabled?(project, feature)
      return false if project.paid_local_activation?

      activation_candidate_prs(project, feature).find_each
        .any? { |pull_request| pull_request_feature_enabled?(project:, pull_request:, feature:) }
    end

    def label_name(project, feature)
      project.feature_activation_label_for(feature)
    end

    # Cheap SQL pre-filter so setting-off projects without labeled work skip
    # the per-PR trust checks (and their GitHub API calls) entirely: only PRs
    # carrying the feature's activation label — or, for features the
    # paid-in-full catchall can activate, PRs whose parent issue carries the
    # catchall — could ever pass pull_request_feature_enabled?. This runs
    # several times per poll tick across the scan/security/release
    # activities, so it must stay a single indexed query when nothing is
    # labeled.
    private_class_method def activation_candidate_prs(project, feature)
      base = project.issues.pull_requests_only.where(github_state: "open")
      label = label_name(project, feature)
      labeled = label.present? ? base.where("labels @> ?", [ label ].to_json) : base.none

      catchall_label = label_name(project, "paid_in_full")
      return labeled if feature == "auto_merge" || catchall_label.blank?

      # Bound the catchall subquery by parents referenced by open PRs: a
      # labeled parent issue with no open child PR cannot produce a candidate
      # (the consumer joins back to `base` via `parent_issue_id`), and a
      # full-project scan grows unboundedly with every paid-in-full issue
      # ever labeled — exceeding GitHub's hourly rate limit on setting-off
      # projects with history. The `id IN (parent_ids)` filter uses the
      # primary key index, so the jsonb containment check runs against a
      # small set without needing a non-partial GIN index on issues.labels.
      parent_ids = base.where.not(parent_issue_id: nil).distinct.pluck(:parent_issue_id)
      return labeled if parent_ids.empty?

      catchall_parents = project.issues
        .where(is_pull_request: false, id: parent_ids)
        .where("labels @> ?", [ catchall_label ].to_json)
        .select(:id)
      labeled.or(base.where(parent_issue_id: catchall_parents)).includes(:parent_issue)
    end

    private_class_method def upstream_mode_disables?(project, feature)
      return false unless project.upstream_mode_skips?(feature)

      project.log_upstream_mode_skipped(feature)
      true
    end

    private_class_method def blocked_by_skip_labels?(project, issue)
      return false unless issue

      (Array(issue.labels) & Array(project.effective_auto_pick_skip_labels)).any?
    end

    # Returns the sentinel that signals "this issue is paid-activated" to
    # {Automation::LabelPolicy#label_decision_for} without a label read. The
    # sentinel is consumed by that policy's explicit local-activation path,
    # so it never attempts to replay a GitHub label event that cannot exist.
    # @spec LABEL-CONTROL-007
    def paid_local_trigger(issue)
      issue&.paid_activated? ? Issue::PAID_ACTIVATION_SENTINEL : nil
    end

    private_class_method def trusted_issue_specific_label(project, issue, feature)
      label = label_name(project, feature)
      return unless label.present?
      return unless issue.has_label?(label)
      return unless Automation::LabelPolicy.trusted_user_added_label?(project, issue, label)

      label
    end

    private_class_method def trusted_pr_specific_label(project, pull_request, feature)
      label = label_name(project, feature)
      return unless label.present?
      return unless pull_request.has_label?(label)
      return unless Automation::LabelPolicy.trusted_user_added_label?(project, pull_request, label)

      label
    end

    private_class_method def trusted_parent_issue_catchall_label(project, pull_request)
      parent_issue = pull_request.parent_issue
      return unless parent_issue

      trusted_issue_specific_label(project, parent_issue, "paid_in_full")
    end

    private_class_method def project_setting_enabled?(project, feature)
      case feature.to_s
      when "auto_pick"
        project.auto_pick_enabled?
      when "auto_enhance"
        project.auto_enhance_enabled?
      when "auto_merge"
        project.auto_merge_enabled?
      when "auto_scan_prs"
        project.auto_scan_prs == true
      when "auto_scan_security"
        project.auto_scan_security == true
      when "auto_fix_merge_conflicts"
        project.auto_fix_merge_conflicts == true
      when "auto_release"
        project.auto_release_enabled?
      else
        false
      end
    end
  end
end
