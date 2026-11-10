# frozen_string_literal: true

module PartialCloseouts
  # Builds the bounded, provenance-labeled inputs for a semantic closeout audit.
  # @spec PARTIAL-CLOSEOUT-047
  class AuditEvidence
    MAX_SOURCE_BODY = 16_000
    MAX_MERGED_PRS = 8
    MAX_PR_BODY = 6_000
    MAX_RUN_SUMMARY = 3_000
    MAX_VERIFICATION_SUMMARY = 1_000

    attr_reader :coverage, :source_revision, :intent_revision

    def self.call(...) = new(...).call

    def self.pr_bodies_for(issue, closeout)
      selected = closeout.merged_prs.last(MAX_MERGED_PRS)
      numbers = selected.map(&:number)
      return {} if numbers.empty?

      rows = Issue.where(project_id: issue.project_id, is_pull_request: true,
        pr_review_phase: "merged", github_number: numbers)
        .pluck(:github_number, :github_html_url, :parent_issue_id, :body)
      rows_by_number = rows.group_by(&:first)
      selected.to_h do |pr|
        row = rows_by_number.fetch(pr.number, []).find do |_number, url, parent_id, _body|
          url == pr.url || (url.nil? && parent_id == issue.id)
        end
        [ [ pr.number, pr.url ], row&.last ]
      end
    end

    def initialize(issue:, agent_run:)
      @issue = issue
      @agent_run = agent_run
    end

    def call
      closeout = Issues::CloseoutEvidence.call(@issue)
      merged_prs = closeout.merged_prs.last(MAX_MERGED_PRS)
      pr_bodies = self.class.pr_bodies_for(@issue, closeout)
      runs = AgentRun.where(project_id: @issue.project_id, issue_id: @issue.id,
        goal: "create_pr", id: merged_prs.filter_map(&:run_id)).index_by(&:id)
      source = source_issue
      @source_revision = Assessment.source_revision_for(@issue, closeout_evidence: closeout)
      @intent_revision = source.fetch(:intent_revision)
      delivery = merged_prs.map { |pr| merged_pr(pr, runs[pr.run_id], pr_bodies[[ pr.number, pr.url ]]) }
      current = current_run_summary
      omitted = closeout.merged_prs.size - merged_prs.size
      @coverage = coverage_for(source, delivery, current, omitted)

      {
        source_issue: source,
        merged_prs: delivery,
        omitted_merged_pr_count: omitted,
        closeout_evidence_revision: closeout.digest,
        pr_body_revision: closeout.pr_body_revision,
        current_run_summary: current
      }.to_json
    end

    private

    def coverage_for(source, delivery, current, omitted)
      reasons = []
      reasons << "source_issue_body_truncated" if source[:body_truncated]
      reasons << "merged_prs_omitted" if omitted.positive?
      reasons << "merged_pr_body_truncated" if delivery.any? { |pr| pr[:body_truncated] }
      reasons << "merged_pr_body_changed_during_audit" if delivery.any? { |pr| pr[:body_changed_during_audit] }
      warnings = []
      warnings << "merged_run_summary_truncated" if delivery.any? { |pr| pr[:run_summary_truncated] }
      warnings << "verification_summary_truncated" if delivery.any? { |pr| pr[:verification_summary_truncated] }
      warnings << "current_run_summary_truncated" if current && current[:truncated]
      { "complete" => reasons.empty?, "reasons" => reasons, "warnings" => warnings }
    end

    def source_issue
      body = @issue.body.to_s
      {
        number: @issue.github_number,
        title: @issue.title,
        body: body.first(MAX_SOURCE_BODY),
        body_truncated: body.length > MAX_SOURCE_BODY,
        intent_revision: Assessment.intent_revision_for(@issue)
      }
    end

    def merged_pr(pr, run, body)
      summary = run&.agent_summary_with_stderr_fallback(limit: 200).to_s
      body = body.to_s
      verification = run&.verification_result.to_h || {}
      verification_summary = verification["summary"].to_s
      {
        number: pr.number,
        url: pr.url,
        body: body.first(MAX_PR_BODY),
        body_missing: body.empty?,
        body_truncated: body.length > MAX_PR_BODY,
        body_changed_during_audit: Digest::SHA256.hexdigest(body) != pr.body_digest,
        originating_run_id: run&.id,
        run_status: run&.status,
        commit: run&.result_commit_sha,
        run_summary: summary.first(MAX_RUN_SUMMARY),
        run_summary_missing: summary.empty?,
        run_summary_truncated: summary.length > MAX_RUN_SUMMARY,
        verification_status: verification["status"],
        verification_summary: verification_summary.first(MAX_VERIFICATION_SUMMARY),
        verification_missing: verification.empty?,
        verification_summary_truncated: verification_summary.length > MAX_VERIFICATION_SUMMARY
      }
    end

    def current_run_summary
      return unless @agent_run.goal == "create_pr"

      summary = @agent_run.agent_summary_with_stderr_fallback(limit: 200).to_s
      { text: summary.first(MAX_RUN_SUMMARY), missing: summary.empty?, truncated: summary.length > MAX_RUN_SUMMARY }
    end
  end
end
