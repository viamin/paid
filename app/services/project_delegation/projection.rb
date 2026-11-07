# frozen_string_literal: true

module ProjectDelegation
  # RDR-080 "One policy contract and revision boundaries": the shared
  # delegation read model every surface consumes — settings, agent-run
  # detail, Inbox, API, and MCP. It projects each governing bounded
  # authorization together with the effective policy Automation::EffectivePolicy
  # computes for that authorization's own work item, so no surface infers
  # authority from a label, stale approval, queue state, or local UI state.
  #
  # Rollout: default-off behind the per-project +project_delegation+ gate.
  # While the gate is off the projection reports disabled with no
  # authorizations and surfaces render no delegation authority at all.
  #
  # @spec PROJECT-DELEGATION-005
  class Projection
    FLAG = :project_delegation
    # Governing rows are selected in SQL before materialization so a long
    # authorization history cannot hide the row that currently governs a
    # lineage behind a capped materialized list.
    AUTHORIZATION_LIMIT = 200

    Authorization = Data.define(
      :authorization_id, :action, :status, :expires_at,
      :issue_id, :issue_number, :issue_title,
      :phase, :stop_before_phase, :posture_signature, :effective_policy
    ) do
      def permitted? = effective_policy[:permitted] == true
      def authority_source = effective_policy[:source]

      # One shared attribution sentence, so every surface names the same
      # authority the shared policy contract returned.
      # @spec PROJECT-DELEGATION-005
      def authority_label
        case authority_source
        when :legacy_policy then "legacy policy"
        when :continuation_grant then "continuation grant"
        when :project_defaults then "project phase defaults"
        when :manual_action then "manual action"
        else "not permitted under the current policy"
        end
      end

      def to_h
        {
          authorization_id:, action:, status:, expires_at: expires_at&.iso8601,
          issue_id:, issue_number:, issue_title:,
          phase:, stop_before_phase:, posture_signature:,
          effective_policy:
        }
      end
    end

    Result = Data.define(:enabled, :phase_model_enabled, :authorizations) do
      def to_h
        { enabled:, phase_model_enabled:, authorizations: authorizations.map(&:to_h) }
      end
    end

    class << self
      def call(...) = new(...).call

      # @spec PROJECT-DELEGATION-005
      def enabled?(project)
        FeatureFlags.enabled?(FLAG, project:)
      end
    end

    def initialize(project:, issue: nil)
      @project = project
      @issue = issue
    end

    def call
      Result.new(
        enabled: enabled?,
        phase_model_enabled: phase_model_enabled?,
        authorizations: enabled? ? projected : []
      )
    end

    private

    attr_reader :project, :issue

    def enabled?
      @enabled = self.class.enabled?(project) if @enabled.nil?
      @enabled
    end

    def phase_model_enabled?
      @phase_model_enabled = Automation::RolloutGuard.enabled?(project) if @phase_model_enabled.nil?
      @phase_model_enabled
    end

    # The latest authorization per (work item, action) governs the lineage —
    # the same selection rule DelegatedActionAdmission applies at boundaries.
    def governing_rows
      scope = project.bounded_delegated_actions
        .select("DISTINCT ON (issue_id, action) *")
        .order(:issue_id, :action, id: :desc)
        .includes(:issue)
        .limit(AUTHORIZATION_LIMIT)
      scope = scope.where(issue: issue) if issue
      scope.to_a
    end

    def projected
      rows = governing_rows
      grants = continuation_grants_by_issue(rows.map(&:issue))
      rows.map { |row| project_row(row, grants) }
    end

    def project_row(row, grants)
      phase = Automation::DelegatedActionAdmission::ACTION_PHASES.fetch(row.action)
      policy = Automation::EffectivePolicy.call(
        project:, phase:, work_item: row.issue, trigger: :automatic,
        continuation_grants: grants[row.issue_id], rollout_enabled: phase_model_enabled?
      )
      Authorization.new(
        authorization_id: row.id, action: row.action, status: row.status,
        expires_at: row.expires_at, issue_id: row.issue_id,
        issue_number: row.issue.github_number, issue_title: row.issue.title,
        phase:, stop_before_phase: row.evidence["stop_before_phase"],
        posture_signature: row.evidence["posture_signature"],
        effective_policy: policy.to_h
      )
    end

    # One batched read of the continuation grants reachable from any projected
    # work item's chain (the issue, its parent when it is a pull request, and
    # their linked pull requests — ContinuationGrantLookup chain semantics),
    # so per-authorization policy decisions do not query grants row by row.
    def continuation_grants_by_issue(issues)
      chains = chains_by_root(issues)
      return {} if chains.empty?

      grants = WorkItemContinuationGrant.active
        .where(project_id: project.id, issue_id: chains.values.flatten.uniq)
        .order(:id).to_a
      chains.each_with_object({}) do |(root_id, chain_ids), index|
        index[root_id] = grants.select { |grant| chain_ids.include?(grant.issue_id) }
      end
    end

    def chains_by_root(issues)
      roots = issues.each_with_object({}) do |work_item, index|
        root_ids = [ work_item.id ]
        root_ids << work_item.parent_issue_id if work_item.is_pull_request? && work_item.parent_issue_id.present?
        index[work_item.id] = root_ids
      end
      child_ids_by_parent = Issue
        .where(parent_issue_id: roots.values.flatten.uniq, is_pull_request: true)
        .pluck(:parent_issue_id, :id)
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) { |(parent, id), hash| hash[parent] << id }
      roots.transform_values { |root_ids| (root_ids + root_ids.flat_map { |parent| child_ids_by_parent[parent] }).uniq }
    end
  end
end
