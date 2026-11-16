# frozen_string_literal: true

module Issues
  # Finds the newest durable input that can affect partial-closeout lane
  # membership. Batch lookup keeps the reconciliation sweep's query count
  # independent of the number of projects in each page.
  # @spec PARTIAL-CLOSEOUT-042
  class PartialCloseoutProjectionInputWatermark
    Snapshot = Data.define(:watermark, :fingerprint)

    def self.for(project)
      new([ project ]).snapshots.fetch(project.id)
    end

    def self.for_projects(projects)
      new(projects).snapshots
    end

    def initialize(projects)
      @projects = projects
      @project_ids = projects.map(&:id)
    end

    def snapshots
      signatures = initial_signatures
      watermarks = projects.to_h { |project| [ project.id, project.updated_at ] }
      project_scopes.each { |name, scope, project_column| merge_signatures(signatures, watermarks, name, scope, project_column) }
      merge_runner_signatures(signatures, watermarks)
      signatures.to_h do |project_id, parts|
        snapshot = Snapshot.new(
          watermark: watermarks.fetch(project_id),
          fingerprint: Digest::SHA256.hexdigest(JSON.generate(parts))
        )
        [ project_id, snapshot ]
      end
    end

    private

    attr_reader :project_ids, :projects

    def initial_signatures
      projects.to_h do |project|
        [ project.id, [ signature("project", 1, project.updated_at) ] ]
      end
    end

    def project_scopes
      [
        [ "issues", Issue.where(project_id: project_ids), Issue.arel_table[:project_id] ],
        [ "agent_runs", AgentRun.where(project_id: project_ids), AgentRun.arel_table[:project_id] ],
        [ "continuation_requests", IssueContinuationRequest.where(project_id: project_ids), IssueContinuationRequest.arel_table[:project_id] ],
        [ "issue_dependencies", IssueDependency.joins(:issue).where(issues: { project_id: project_ids }), Issue.arel_table[:project_id] ],
        [ "remediation_attempts", CodeScanningRemediationAttempt.joins(:issue).where(issues: { project_id: project_ids }), Issue.arel_table[:project_id] ],
        [ "model_selections", ModelSelection.joins(:agent_run).where(agent_runs: { project_id: project_ids }), AgentRun.arel_table[:project_id] ],
        [ "feature_intents", FeatureIntent.where(project_id: project_ids), FeatureIntent.arel_table[:project_id] ],
        [ "feature_intent_issues", FeatureIntentIssue.joins(:issue).where(issues: { project_id: project_ids }), Issue.arel_table[:project_id] ],
        [ "feature_intent_dependencies", FeatureIntentIssueDependency.joins(feature_intent_issue: :issue).where(issues: { project_id: project_ids }), Issue.arel_table[:project_id] ],
        [ "prerequisite_mappings", FeatureIntentIssuePrerequisiteMapping.joins(feature_intent_issue: :issue).where(issues: { project_id: project_ids }), Issue.arel_table[:project_id] ],
        [ "prerequisites", FeatureIntentIssuePrerequisite.joins(feature_intent_issue_prerequisite_mapping: { feature_intent_issue: :issue })
          .where(issues: { project_id: project_ids }), Issue.arel_table[:project_id] ],
        [ "notifications", Notification.joins("INNER JOIN issues ON issues.id = notifications.subject_id")
          .where(subject_type: "Issue", issues: { project_id: project_ids }), Issue.arel_table[:project_id] ]
      ]
    end

    def merge_signatures(result, watermarks, name, scope, project_column)
      grouped = scope.group(project_column)
      counts = grouped.count
      maximums = grouped.maximum(scope.klass.arel_table[:updated_at])
      result.each_key do |project_id|
        timestamp = maximums[project_id]
        result[project_id] << signature(name, counts.fetch(project_id, 0), timestamp)
        watermarks[project_id] = [ watermarks[project_id], timestamp ].compact.max
      end
    end

    def merge_runner_signatures(result, watermarks)
      account_ids = projects.map(&:account_id).uniq
      grouped = Runner.joins(:user).where(users: { account_id: account_ids }).group("users.account_id")
      counts = grouped.count
      maximums = grouped.maximum(:updated_at)
      projects.each do |project|
        timestamp = maximums[project.account_id]
        result[project.id] << signature("runners", counts.fetch(project.account_id, 0), timestamp)
        watermarks[project.id] = [ watermarks[project.id], timestamp ].compact.max
      end
    end

    def signature(name, count, timestamp)
      [ name, count, timestamp&.utc&.iso8601(6) ]
    end
  end
end
