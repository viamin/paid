# frozen_string_literal: true

require "json"

module IntentConformance
  # Independent intent-conformance reviewer run (RDR-067 §Decision, #3866).
  # Compares the current PR diff and the implementing agent's self-reported
  # verification evidence with the feature's approved RDR/LID design content
  # at the exact `approved_design_revision`, then persists a structured,
  # cited `IntentConformanceVerdict`. This is the only writer of verdict
  # rows: an implementation agent's self-report never supplies the outcome.
  #
  # ZFC boundary: the LLM makes the semantic within_scope/material_drift/
  # uncertain judgment; Rails performs only structural validation (known
  # outcome enum, cited claims required for a blocking outcome, well-formed
  # citation arrays) and never trusts an unsuccessful, unparseable, or
  # structurally invalid response — every failure mode records
  # `not_evaluated` (fail closed), mirroring DesignAmendments::ImpactReview.
  # @spec INTENT-CONFORMANCE-REVIEW-001
  # @spec INTENT-CONFORMANCE-REVIEW-002
  # @spec INTENT-CONFORMANCE-REVIEW-003
  # @spec INTENT-CONFORMANCE-REVIEW-004
  # @spec INTENT-CONFORMANCE-REVIEW-005
  # @spec INTENT-CONFORMANCE-REVIEW-006
  # @spec INTENT-CONFORMANCE-REVIEW-007
  class ReviewRun
    DEFAULT_MODEL = ReviewerLlm::DEFAULT_MODEL
    NOT_EVALUATED_REVIEWER_MODEL = "none"
    MAX_DESIGN_DOCS = 10
    MAX_DESIGN_DOC_LENGTH = 6_000
    MAX_FILES = 40
    MAX_PATCH_LENGTH = 800
    MAX_VERIFICATION_SUMMARY_LENGTH = 500
    GITHUB_TOKEN_IN_TEXT = /\b(?:ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|gh[oushr]_[A-Za-z0-9]{36,})\b/
    SECRET_PATTERNS = (StyleGuides::CollectCodeSamples::SECRET_PATTERNS + [ GITHUB_TOKEN_IN_TEXT ]).freeze

    def self.call(...)
      new(...).call
    end

    attr_reader :failure_reason

    def initialize(project:, issue:, pr_head_sha:)
      @project = project
      @issue = issue
      @pr_head_sha = pr_head_sha
    end

    def call
      return nil unless applicable?
      return persist_not_evaluated("issue_untrusted") unless issue.trusted?
      return persist_not_evaluated("no_design_documents") if design_docs.empty?

      diff = fetch_diff
      return persist_not_evaluated("no_diff") if diff.blank?

      result = request_review(diff)
      return persist_not_evaluated(result.status.to_s) unless result.ok?

      persist_verdict(result.validated, result)
    end

    private

    attr_reader :project, :issue, :pr_head_sha

    def applicable?
      feature_intent.present? && baseline_revision.present? &&
        rollout_enabled?
    end

    # Shadow review must be explicitly opted into. Normal reviews require the
    # complete enforcement pair and cannot silently run as shadow evaluation.
    def rollout_enabled?
      FeatureFlags.enabled?(:intent_conformance_shadow_review, project: project) ||
        enforcement_enabled?
    end

    def enforcement_enabled?
      FeatureFlags.enabled?(:approved_intent_amendments, project: project) &&
        FeatureFlags.enabled?(:intent_conformance_enforcement, project: project)
    end

    def feature_intent
      @feature_intent ||= confidence_link&.feature_intent || issue.feature_intent
    end

    def client
      @client ||= project.client
    end

    def design_docs
      @design_docs ||= design_document_paths.first(MAX_DESIGN_DOCS).filter_map do |path|
        content = client&.file_content(project.full_name, path: path, ref: baseline_revision)
        next if content.blank?

        { path: path, content: sanitized_prompt_text(content, max_length: MAX_DESIGN_DOC_LENGTH) }
      rescue GithubClient::Error
        nil
      end
    end

    def fetch_diff
      return if client.nil?

      pr_data = client.pull_request(project.full_name, issue.github_number)
      base_sha = pr_data&.base&.sha
      return if base_sha.blank?

      client.compare_summary(project.full_name, base_sha, pr_head_sha).merge(base_sha: base_sha)
    rescue GithubClient::Error
      nil
    end

    def verification_evidence
      run = AgentRun.where(project_id: project.id, pull_request_number: issue.github_number)
        .order(created_at: :desc).first
      return "No verification evidence was available." unless run

      result = run.verification_result || {}
      status = result["status"].to_s
      summary = result["summary"].to_s
      return "No verification evidence was available." if status.blank? && summary.blank?

      "status: #{sanitized_prompt_text(status)}\nsummary: #{sanitized_prompt_text(summary, max_length: MAX_VERIFICATION_SUMMARY_LENGTH)}"
    end

    # Delegates to the shared reviewer core so the production verdict and
    # the shadow evaluation execute the exact same reviewer.
    def request_review(diff)
      ReviewerLlm.call(
        repository: project.full_name,
        revision: baseline_revision,
        design_docs: design_docs,
        base_sha: diff[:base_sha],
        head_sha: pr_head_sha,
        diff: diff_entries(diff),
        verification: verification_evidence
      )
    end

    # @spec CONFIDENCE-DELIVERY-010
    def baseline_revision
      return confidence_link.released_baseline_revision if confidence_link&.release_state == "released"
      return if confidence_link

      feature_intent.approved_design_revision if feature_intent&.approval_gated?
    end

    def design_document_paths
      return Array(confidence_link.current_readiness_mapping["design_artifacts"]).filter_map { |artifact| artifact["path"] } if confidence_link

      Array(feature_intent.design_document_paths)
    end

    def confidence_link
      @confidence_link ||= FeatureIntentIssue.joins(:feature_intent)
        .where(issue_id: issue.id, feature_intents: { delivery_policy: "confidence_driven" })
        .order(:id).first
    end

    def diff_entries(diff)
      Array(diff[:files]).first(MAX_FILES).map do |file|
        {
          filename: sanitized_prompt_text(file[:filename]),
          status: sanitized_prompt_text(file[:status]),
          additions: file[:additions],
          deletions: file[:deletions],
          patch_excerpt: patch_for(file)
        }.compact
      end
    end

    def patch_for(file)
      patch = file[:patch].to_s
      return if patch.blank?

      sanitized_prompt_text(patch, max_length: MAX_PATCH_LENGTH, omission: "\n[truncated]")
    end


    def persist_verdict(validated, result)
      IntentConformanceVerdict.create!(
        project: project,
        issue: issue,
        pr_head_sha: pr_head_sha,
        approved_design_revision: baseline_revision,
        outcome: validated[:outcome],
        evaluated_at: Time.current,
        reviewer_model: result.model.presence || DEFAULT_MODEL,
        cited_claims: validated[:cited_design_claims].map { |claim| { "claim_text" => claim } },
        cited_diff_locations: validated[:cited_diff_locations],
        reasoning_summary: validated[:reasoning_summary]
      )
    end

    def persist_not_evaluated(reason)
      @failure_reason = reason
      log_failure(reason)

      IntentConformanceVerdict.create!(
        project: project,
        issue: issue,
        pr_head_sha: pr_head_sha,
        approved_design_revision: baseline_revision,
        outcome: IntentConformanceVerdict::OUTCOME_NOT_EVALUATED,
        evaluated_at: Time.current,
        reviewer_model: NOT_EVALUATED_REVIEWER_MODEL,
        cited_claims: [],
        cited_diff_locations: [],
        reasoning_summary: "Review could not be completed: #{reason}."
      )
    end

    def log_failure(reason)
      Rails.logger.warn(
        message: "intent_conformance.review_run_invalid",
        project_id: project.id,
        issue_id: issue.id,
        reason: reason
      )
    end

    def sanitized_prompt_text(text, max_length: nil, omission: " [truncated]")
      sanitized = redact_secrets(Knowledge::Redaction::Redactor.call(text: normalized_text(text)).clean_text)
      return sanitized if max_length.nil?

      sanitized.truncate(max_length, omission: omission)
    end

    def normalized_text(text)
      text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "").delete("\x00")
    end

    def redact_secrets(text)
      SECRET_PATTERNS.reduce(text) do |result, pattern|
        result.gsub(pattern) do
          if Regexp.last_match.captures.any?
            "#{Regexp.last_match[1]}[REDACTED]"
          else
            "[REDACTED]"
          end
        end
      end
    end
  end
end
