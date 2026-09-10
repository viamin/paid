# frozen_string_literal: true

module Automation
  module FeatureActivation
    module_function

    # @spec AUTOMATION-ACTIVATION-003 @spec AUTOMATION-ACTIVATION-004 @spec AUTOMATION-ACTIVATION-005 @spec AUTOMATION-ACTIVATION-006
    def issue_auto_pick_trigger(project:, issue:)
      return nil if blocked_by_skip_labels?(project, issue)

      label = trusted_issue_specific_label(project, issue, "auto_pick")
      return label if label.present?

      trusted_issue_specific_label(project, issue, "paid_in_full")
    end

    def issue_auto_enhance_enabled?(project:, issue:)
      return true if project.auto_enhance_enabled?
      return false if blocked_by_skip_labels?(project, issue)

      trusted_issue_specific_label(project, issue, "auto_enhance").present? ||
        trusted_issue_specific_label(project, issue, "paid_in_full").present?
    end

    def issue_tdd_mode(project:, issue:)
      return project.tdd_mode if project.tdd_mode.in?(%w[strict non_strict])
      return "off" unless issue
      return "off" if blocked_by_skip_labels?(project, issue)

      return "strict" if trusted_issue_specific_label(project, issue, "tdd_strict").present?
      return "non_strict" if trusted_issue_specific_label(project, issue, "tdd_auto").present?
      return "strict" if trusted_issue_specific_label(project, issue, "paid_in_full").present?

      "off"
    end

    def pull_request_feature_enabled?(project:, pull_request:, feature:)
      return true if project_setting_enabled?(project, feature)
      return false unless pull_request

      return true if trusted_pr_specific_label(project, pull_request, feature).present?

      return false if feature == "auto_merge"

      trusted_parent_issue_catchall_label(project, pull_request).present?
    end

    def any_pull_request_feature_enabled?(project:, feature:)
      return true if project_setting_enabled?(project, feature)

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

    private_class_method def blocked_by_skip_labels?(project, issue)
      return false unless issue

      (Array(issue.labels) & Array(project.effective_auto_pick_skip_labels)).any?
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
