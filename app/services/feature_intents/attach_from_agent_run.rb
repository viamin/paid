# frozen_string_literal: true

module FeatureIntents
  # Wires `create_feature` and `lid_planning` agent runs to a
  # `FeatureIntent` so the Inbox decision flow (FEATURE-APPROVAL-013),
  # readiness gate (FEATURE-APPROVAL-011), and Mark approved action
  # (FEATURE-APPROVAL-012) operate on real records — not a dormant
  # substrate. This is the single choke point for the four attachment
  # operations RDR-066 + #3863 own:
  #
  # - `call` — creates the `FeatureIntent` when a `create_feature` /
  #   `lid_planning` run is queued (status `discovering`), links the brief
  #   issue the run files, and stores the brief text.
  # - `attach_design_pr` — records a `FeatureIntentDesignPr` when the
  #   docs-only PR opens, reading the PR number and head SHA from GitHub
  #   (never from the agent's output, per FEATURE-APPROVAL-018).
  # - `attach_issue` — links an implementation issue the run filed to the
  #   `FeatureIntent` via a `FeatureIntentIssue` row, so the Inbox detail
  #   view can list the proposed tree alongside the design PR.
  # - `detach_on_close!` — reconciles the design PR being closed unmerged:
  #   transitions the feature to `cancelled` and closes every linked
  #   `FeatureIntentIssue` so no runnable orphan issue remains
  #   (RDR-066 acceptance criterion #3).
  #
  # Putting all four operations in one service means the
  # `create_feature` path and the chained `lid_planning` path cannot
  # disagree about what a `FeatureIntent` records, and the
  # closed-unmerged reconciliation case (#3865) inherits the same
  # attachment logic by calling the same service.
  # @spec FEATURE-APPROVAL-014 @spec FEATURE-APPROVAL-015 @spec FEATURE-APPROVAL-016 @spec FEATURE-APPROVAL-017 @spec FEATURE-APPROVAL-018
  class AttachFromAgentRun
    Result = Data.define(:feature_intent) do
      def feature_intent? = feature_intent.present?
    end
    DesignPrResult = Data.define(:design_pr) do
      def design_pr? = design_pr.present?
    end
    IssueLinkResult = Data.define(:feature_intent_issue) do
      def linked? = feature_intent_issue.present?
    end
    DetachResult = Data.define(:feature_intent, :cancelled, :closed_issue_count) do
      def cancelled? = cancelled
    end

    def self.call(...)
      new(...).call
    end

    def self.attach_design_pr(feature_intent:, pull_request_number:, head_sha:, design_pr_kind: "rdr", required: nil)
      new(
        feature_intent: feature_intent,
        pull_request_number: pull_request_number,
        head_sha: head_sha,
        design_pr_kind: design_pr_kind,
        required: required
      ).attach_design_pr
    end

    def self.attach_issue(feature_intent:, issue:)
      new(feature_intent: feature_intent, issue: issue).attach_issue
    end

    def self.detach_on_close!(feature_intent:, pull_request_number:, merged:)
      new(
        feature_intent: feature_intent,
        pull_request_number: pull_request_number,
        merged: merged
      ).detach_on_close!
    end

    def initialize(agent_run: nil, goal: nil, brief: nil, feature_intent: nil, pull_request_number: nil,
      head_sha: nil, design_pr_kind: nil, required: nil, issue: nil, merged: nil)
      @agent_run = agent_run
      @goal = goal
      @brief = brief
      @feature_intent = feature_intent
      @pull_request_number = pull_request_number
      @head_sha = head_sha
      @design_pr_kind = design_pr_kind
      @required = required
      @issue = issue
      @merged = merged
    end

    # @spec FEATURE-APPROVAL-014
    def call
      return Result.new(feature_intent: nil) unless goal_in_scope?
      return Result.new(feature_intent: existing_feature_intent) if existing_feature_intent

      project = agent_run.project
      issue = agent_run.issue
      ActiveRecord::Base.transaction do
        feature_intent = FeatureIntent.create!(
          project: project,
          title: feature_title,
          brief: formatted_brief,
          status: "discovering",
          criteria_clarity_state: "pending"
        )
        FeatureIntentIssue.create!(feature_intent: feature_intent, issue: issue) if issue
        Result.new(feature_intent: feature_intent)
      end
    rescue ActiveRecord::RecordInvalid
      Result.new(feature_intent: nil)
    end

    # @spec FEATURE-APPROVAL-015
    def attach_design_pr
      return DesignPrResult.new(design_pr: nil) if feature_intent.nil? || pull_request_number.nil? || head_sha.blank?

      design_pr = feature_intent.feature_intent_design_prs.find_by(pull_request_number: pull_request_number)
      if design_pr
        # @spec FEATURE-APPROVAL-018 — head SHA comes from GitHub. When a new
        # commit lands after the first attachment, advance head_sha and leave
        # reviewed_head_sha where it was so ApprovalReadiness can flag the
        # staleness; re-evaluation moves reviewed_head_sha forward.
        prior_reviewed_head_sha = design_pr.reviewed_head_sha.presence || design_pr.head_sha
        design_pr.update!(head_sha: head_sha, reviewed_head_sha: prior_reviewed_head_sha)
        DesignPrResult.new(design_pr: design_pr)
      else
        created = feature_intent.feature_intent_design_prs.create!(
          pull_request_number: pull_request_number,
          head_sha: head_sha,
          reviewed_head_sha: head_sha,
          design_pr_kind: design_pr_kind || "rdr",
          required: required.nil? ? required_for_kind : required
        )
        DesignPrResult.new(design_pr: created)
      end
    end

    # @spec FEATURE-APPROVAL-016
    def attach_issue
      return IssueLinkResult.new(feature_intent_issue: nil) if feature_intent.nil? || issue.nil?

      link = feature_intent.feature_intent_issues.find_by(issue_id: issue.id)
      return IssueLinkResult.new(feature_intent_issue: link) if link

      IssueLinkResult.new(
        feature_intent_issue: feature_intent.feature_intent_issues.create!(issue: issue)
      )
    rescue ActiveRecord::RecordInvalid
      IssueLinkResult.new(feature_intent_issue: nil)
    end

    # @spec FEATURE-APPROVAL-017
    def detach_on_close!
      return DetachResult.new(feature_intent: feature_intent, cancelled: false, closed_issue_count: 0) if feature_intent.nil?

      design_pr = feature_intent.feature_intent_design_prs.find_by(pull_request_number: pull_request_number)
      return DetachResult.new(feature_intent: feature_intent, cancelled: false, closed_issue_count: 0) if design_pr.nil?

      if merged
        design_pr.update!(merged_at: Time.current) unless design_pr.merged_at.present?
        return DetachResult.new(feature_intent: feature_intent, cancelled: false, closed_issue_count: 0)
      end

      # Closed-unmerged: cancel the feature and close every linked issue so
      # no runnable orphan remains. Defense in depth — the per-issue close
      # is best-effort (Issue#close! may fail on a stale state), but the
      # feature cancellation must land even if a single close fails.
      closed_issue_count = 0
      ActiveRecord::Base.transaction do
        feature_intent.update!(status: "cancelled")
        feature_intent.feature_intent_issues.includes(:issue).each do |link|
          next unless link.issue.github_state == "open"

          link.issue.update!(github_state: "closed", closed_at: Time.current)
          closed_issue_count += 1
        end
      end
      DetachResult.new(feature_intent: feature_intent, cancelled: true, closed_issue_count: closed_issue_count)
    end

    private

    attr_reader :agent_run, :goal, :brief, :feature_intent, :pull_request_number, :head_sha,
      :design_pr_kind, :required, :issue, :merged

    # `create_feature` and `lid_planning` are the only goals this attachment
    # flow owns. Any other goal (create_pr, enhance_issue, …) is a no-op so
    # the service can be safely called from a generic dispatch point
    # without gating on goal upstream.
    def goal_in_scope?
      %w[create_feature lid_planning].include?(goal.to_s)
    end

    def existing_feature_intent
      @existing_feature_intent ||= begin
        project = agent_run&.project
        brief_issue = agent_run&.issue
        return nil unless project

        candidates = FeatureIntent.where(project_id: project.id)
        candidates = candidates.joins(:feature_intent_issues).where(feature_intent_issues: { issue_id: brief_issue.id }) if brief_issue
        candidates.first
      end
    end

    def feature_title
      raw = brief.respond_to?(:[]) ? brief["title"] : nil
      raw = (raw.presence || agent_run&.issue&.title).to_s
      raw.lines.first.to_s.strip.truncate(120).presence || "New Feature"
    end

    def formatted_brief
      lines = []
      if brief.is_a?(Hash)
        brief.each do |key, value|
          next if value.blank?

          lines << "#{key.to_s.tr('_', ' ').capitalize}: #{value}" unless value.is_a?(Hash) || value.is_a?(Array)
        end
        lines.concat(problem_framing_section(brief["problem_framing"])) if brief["problem_framing"].is_a?(Hash)
      end
      return agent_run&.external_metadata&.dig("feature_brief", "problem") if lines.empty?

      lines.join("\n")
    end

    def problem_framing_section(framing)
      framing.filter_map do |key, value|
        "#{key.to_s.tr('_', ' ').capitalize}: #{value}" unless value.blank? || value.is_a?(Hash) || value.is_a?(Array)
      end
    end

    # LID-mode projects require the chained `lid_planning` design PR to
    # merge before implementation; non-LID projects treat it as optional
    # because RDR-066 deliberately keeps LID outside the whole-feature
    # approval contract when the project has not enabled LID.
    def required_for_kind
      return false unless design_pr_kind.to_s == "lid_planning"

      feature_intent.project.lid_mode.present?
    end
  end
end
