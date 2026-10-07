# frozen_string_literal: true

# Entry point for assembling create_pr issue-implementation prompts through
# PromptAssembly. Pre-fetches shared data (issue comments), configures the
# ordered section providers, and delegates to {PromptAssembly::Build}.
#
# The assembled prompt preserves the content and ordering of the legacy
# {Prompts::BuildForIssue} path while adding full section provenance and
# keeping the task and safety-rules sections required (never suppressed).
#
# @spec PROMPT-ASSEMBLY-014
#
# @example
#   result = PromptAssembly::BuildIssuePrompt.call(
#     issue: issue, project: project, github_client: client, agent_run: run
#   )
#   result.text        # => "# Task\n\nYou are working on..."
#   result.provenance  # => { digest: "...", sections: [...], ... }
class PromptAssembly::BuildIssuePrompt
  UntrustedIssueError = Prompts::BuildForIssue::UntrustedIssueError

  # Raised when a queued code-scanning remediation run's alert was fixed or
  # dismissed upstream since the run was queued. Signals the caller to stop
  # this run rather than execute a remediation prompt for a resolved finding.
  class AlertResolvedError < StandardError; end

  # The alert is still open, but its evidence cannot safely identify what may
  # be changed. This is intentionally separate from AlertResolvedError: it
  # needs operator attention, while a resolved alert simply stops work.
  class AlertEvidenceError < StandardError
    attr_reader :retryable

    def initialize(message, retryable: false)
      @retryable = retryable
      super(message)
    end

    def retryable?
      retryable
    end
  end

  def self.call(...)
    new(...).call
  end

  def self.refresh_code_scanning_context(...)
    new(...).refresh_code_scanning_context
  end

  attr_reader :issue, :project, :github_client, :agent_run

  def initialize(issue:, project:, github_client: nil, agent_run: nil)
    @issue = issue
    @project = project
    @github_client = github_client
    @agent_run = agent_run
  end

  def call
    raise UntrustedIssueError,
      "Cannot build prompt for issue from untrusted user: #{issue.github_creator_login}" unless issue.trusted?

    refresh_code_scanning_context

    context = PromptAssembly::Context.new(
      issue: issue,
      project: project,
      github_client: github_client,
      agent_run: agent_run,
      issue_comments: fetched_comments
    )

    PromptAssembly::Build.call(
      sections: sections_for(context),
      profile: resolved_profile
    )
  end

  private

  def resolved_profile
    PromptAssembly::ProfileResolution.resolve(
      project: project,
      account: project&.account,
      goal: agent_run&.goal || "create_pr"
    )
  end

  def sections_for(context)
    [
      PromptAssembly::Sections::IssueTask.call(context),
      PromptAssembly::Sections::TrustedComments.call(context),
      PromptAssembly::Sections::ClarifiedRequirements.call(context),
      PromptAssembly::Sections::ServiceEnvironment.call(context),
      PromptAssembly::Sections::KnowledgeContext.call(context),
      PromptAssembly::Sections::StyleGuides.call(context),
      PromptAssembly::Sections::ProjectConventions.call(context),
      PromptAssembly::Sections::LidWorkflow.call(context),
      PromptAssembly::Sections::MarketplaceAttachments.call(context),
      PromptAssembly::Sections::RdrRolloutGuard.call(context),
      PromptAssembly::Sections::SafetyRules.call(context)
    ]
  end

  # Fetched once and shared by TrustedComments and ClarifiedRequirements so
  # the comment thread is downloaded a single time per prompt build.
  def fetched_comments
    @fetched_comments ||= begin
      return [] unless github_client

      github_client.issue_comments(project.full_name, issue.github_number)
    rescue GithubClient::Error
      []
    end
  end

  # A poll snapshot can be old by the time a queued run starts. Refreshing the
  # synthetic issue here ensures the final prompt is built from the current
  # target-branch finding rather than relying on a private GitHub alert URL.
  #
  # If the refresh finds the alert is no longer open, ProcessCodeScanningAlerts
  # closes the synthetic issue and this raises AlertResolvedError so the caller
  # stops the run instead of executing a remediation prompt for a finding that
  # was already fixed or dismissed upstream.
  # @spec GITHUB-SYNC-015
  # @spec GITHUB-SYNC-019
  def refresh_code_scanning_context
    return unless github_client && issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE

    alert_number = issue.github_issue_id - Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET
    alert = github_client.code_scanning_alert(project.full_name, alert_number, default_branch: project.default_branch)
    raise_evidence_error!("alert was not returned by GitHub") unless alert
    raise_evidence_error!("alert state was not returned by GitHub") if alert[:state].blank?

    if alert[:state] != "open"
      process_alert!(alert)
      issue.reload
      raise AlertResolvedError,
        "Code scanning alert ##{alert_number} is no longer open (state: #{alert[:state]})"
    end
    validate_remediation_evidence!(alert, alert_number:)
    process_alert!(alert)
    issue.reload
  rescue GithubClient::Error => e
    message = "Code scanning alert ##{alert_number} evidence refresh failed: #{e.message}"
    block_remediation!(message)
    Rails.logger.warn(
      message: "github_sync.code_scanning_prompt_refresh_blocked",
      project_id: project.id,
      alert_number: alert_number,
      error: e.message
    )
    raise AlertEvidenceError.new(message, retryable: transient_error?(e))
  end

  public :refresh_code_scanning_context

  private

  def process_alert!(alert)
    SecurityAlerts::ProcessCodeScanningAlerts.new(project)
      .call([ alert ], excluding_run_id: agent_run&.id)
  end

  # @spec GITHUB-SYNC-019
  def validate_remediation_evidence!(alert, alert_number:)
    target_ref = "refs/heads/#{project.default_branch}"
    missing = []
    missing << "identity" unless alert[:number].to_i == alert_number
    missing << "target branch" unless project.default_branch.present? && alert[:target_ref] == target_ref && alert[:ref] == target_ref
    missing << "analyzed commit" unless alert[:commit_sha].present?
    missing << "scanner configuration" unless alert[:tool_name].present? && alert[:analysis_key].present?
    location = alert[:location]
    missing << "finding location (#{alert[:location_context_status] || 'unavailable'})" unless location&.dig(:path).present? && location[:start_line].to_i.positive?
    missing << "source evidence at analyzed commit" unless alert[:source_excerpt].present? || alert[:source_read_verified]
    raise_evidence_error!("missing #{missing.join(', ')}") if missing.any?
  end

  def raise_evidence_error!(detail)
    message = "Code scanning remediation blocked: #{detail}"
    block_remediation!(message)
    raise AlertEvidenceError, message
  end

  def block_remediation!(reason)
    return unless issue.respond_to?(:persisted?) && issue.persisted?

    issue.update!(paid_state: "manual_review", manual_review_reason: reason)
  end

  def transient_error?(error)
    error.is_a?(GithubClient::RateLimitError) ||
      (error.is_a?(GithubClient::ApiError) && error.status.to_i >= 500)
  end
end
