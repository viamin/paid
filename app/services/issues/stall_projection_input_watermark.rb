# frozen_string_literal: true

module Issues
  # Digest of the admission-relevant inputs for one project, used as the
  # stall projection checkpoint's input watermark (RDR-081). Any input that
  # changes admission or lane membership moves the digest, so the sweep can
  # recompute exactly the projects whose inputs changed:
  #
  # - closeout evidence (a merged PR row or a no-code-required outcome lives
  #   on the project's issues; a producing run's recorded PR number and
  #   completion live on agent_runs),
  # - blocking runs (agent_runs aggregates),
  # - continuation requests (issue_continuation_requests aggregates),
  # - explicit holds (issue state columns and labels, scanner verification
  #   attempts, prerequisite notifications),
  # - admission-relevant runner configuration (the project owner's runners
  #   and the model catalog backing the tier feasibility set),
  # - feature-intent release and design-revision state.
  class StallProjectionInputWatermark
    def self.for(project)
      new(project).digest
    end

    def initialize(project)
      @project = project
    end

    def digest
      Digest::SHA256.hexdigest(components.map { |component| component.join(":") }.join("|"))
    end

    private

    attr_reader :project

    def components
      [
        [ "project", project.updated_at&.utc&.iso8601, project.paused?, project.quality_paused_at&.utc&.iso8601 ],
        aggregate("issues", Issue.where(project_id: project.id)),
        aggregate("agent_runs", AgentRun.where(project_id: project.id)),
        aggregate("issue_continuation_requests", IssueContinuationRequest.where(project_id: project.id)),
        aggregate("feature_intents", FeatureIntent.where(project_id: project.id)),
        aggregate("feature_intent_issues", FeatureIntentIssue.joins(:feature_intent).where(feature_intents: { project_id: project.id }),
          "feature_intent_issues.updated_at"),
        aggregate("code_scanning_remediation_attempts",
          CodeScanningRemediationAttempt.joins(:issue).where(issues: { project_id: project.id }),
          "code_scanning_remediation_attempts.updated_at"),
        aggregate("prerequisite_notifications", prerequisite_notifications),
        aggregate("runners", Runner.where(user_id: project.created_by_id)),
        aggregate("llm_models", LlmModel.all)
      ]
    end

    def aggregate(name, scope, column = "updated_at")
      count, max_updated = scope.pick(Arel.sql("COUNT(*), MAX(#{column})"))
      [ name, count, max_updated&.utc&.iso8601 ]
    end

    def prerequisite_notifications
      Notification.where(
        account_id: project.account_id,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
        subject_type: "Issue",
        resolved_at: nil,
        dismissed_at: nil
      ).where("notifications.subject_id IN (SELECT id FROM issues WHERE project_id = ?)", project.id)
    end
  end
end
