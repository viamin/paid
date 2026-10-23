# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Executes the actual intent-conformance reviewer for every corpus case
    # through agent_harness (the shared IntentConformance::ReviewerLlm core),
    # only after the reference label set is frozen. Records actual verdicts,
    # reviewer model, prompt digest, cost, and per-case failures; a missing
    # or failed reviewer output is recorded as not_evaluated and never
    # counted as agreement. Re-running retries cases that lack an evaluated
    # verdict. Prerequisite validation alone is never presented as
    # execution.
    # @spec INTENT-CONFORMANCE-ROLLOUT-006
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    class ExecuteReviewer
      Result = Data.define(:success, :error, :evaluation, :executed, :failed) do
        def success? = success
      end

      MAX_DESIGN_DOCS = 10
      MAX_DESIGN_DOC_LENGTH = 6_000
      MAX_FILES = 40
      MAX_PATCH_LENGTH = 800
      NOT_EVALUATED = "not_evaluated"
      VERDICTS = IntentConformance::ShadowEvaluationPolicy::LABELS

      # Namespaces this execution lock apart from the other pg_advisory_lock
      # callers in app/services (each picks its own constant; see
      # PartialCloseouts::ReconcileLegacy, Previews::Lifecycle, etc.).
      ADVISORY_LOCK_NAMESPACE = 1_357_180_008
      ADVISORY_TRY_LOCK_SQL = "SELECT pg_try_advisory_lock(?, ?)".freeze
      ADVISORY_UNLOCK_SQL = "SELECT pg_advisory_unlock(?, ?)".freeze

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless @evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless @evaluation.corpus.matches_recorded_digest?
        return failure("no corpus cases to evaluate") if @evaluation.corpus.case_ids.empty?

        unless try_lock!
          Rails.logger.info(
            message: "intent_conformance.shadow_evaluation_execute_lock_held",
            project_id: @evaluation.project_id,
            shadow_evaluation_id: @evaluation.id
          )
          return failure("reviewer execution is already in progress for this evaluation; retry once it finishes")
        end

        begin
          execute_cases
        ensure
          unlock!
        end
      end

      private

      attr_reader :evaluation

      # Any project operator may trigger execution, so two concurrent calls
      # would both observe "no run row yet" for a case, both invoke the paid
      # reviewer, and the loser's write would then race the unique
      # (shadow_evaluation_id, case_id) index after duplicated LLM spend.
      # The session-scoped try-advisory lock claims execution first; the
      # loser skips with a clear error instead of racing, and a crashed
      # holder releases the lock with its database session so retries stay
      # possible (#4598 review).
      def try_lock!
        ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array([ ADVISORY_TRY_LOCK_SQL, ADVISORY_LOCK_NAMESPACE, @evaluation.id ])
        )
      end

      def unlock!
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ ADVISORY_UNLOCK_SQL, ADVISORY_LOCK_NAMESPACE, @evaluation.id ])
        )
      end

      def execute_cases
        @evaluation.update!(status: "executing", execute_started_at: Time.current)
        executed = 0
        failed = 0

        @evaluation.corpus.cases.each do |corpus_case|
          next if evaluated_run_for(corpus_case.fetch("id"))

          verdict, failure_reason, model, cost = review_case(corpus_case)
          upsert_run(corpus_case, verdict, failure_reason, model, cost)
          verdict == NOT_EVALUATED ? failed += 1 : executed += 1
        end

        complete_or_fail(executed, failed)
      rescue ShadowEvaluationCorpus::MissingManifest => error
        @evaluation.update!(status: "failed", last_failure_reason: error.message)
        failure(error.message)
      end

      def evaluated_run_for(case_id)
        run = @evaluation.runs.find_by(case_id: case_id)
        run if run&.evaluated?
      end

      def review_case(corpus_case)
        preparation = prepare_case(corpus_case)
        return [ NOT_EVALUATED, preparation[:failure], nil, 0 ] if preparation.key?(:failure)

        result = ReviewerLlm.call(
          repository: preparation[:repository],
          revision: preparation[:revision],
          design_docs: preparation[:design_docs],
          base_sha: preparation[:base_sha],
          head_sha: preparation[:head_sha],
          diff: preparation[:diff_entries],
          verification: "No verification evidence was available."
        )
        return [ NOT_EVALUATED, result.status.to_s, nil, 0 ] unless result.ok?

        [ result.validated[:outcome], nil, result.model, result.cost_cents ]
      end

      # Structural preparation only (ZFC): pinned identity resolution, diff
      # and design-doc fetch through the project's existing GitHub client,
      # and secret sanitization. Every failure fails closed.
      def prepare_case(corpus_case)
        repository = corpus_case.fetch("repository")
        return { failure: "case_repository_outside_project" } unless repository == project.full_name

        base_sha = corpus_case.fetch("base_sha")
        head_sha = corpus_case.fetch("head_sha")
        revision = corpus_case.fetch("approved_design_revision")
        docs = design_docs_for(corpus_case, revision)
        return { failure: "no_design_documents" } if docs.empty?

        diff_entries = diff_entries_for(base_sha, head_sha)
        return { failure: "no_diff" } if diff_entries.nil?

        {
          repository: repository,
          revision: revision,
          base_sha: base_sha,
          head_sha: head_sha,
          design_docs: docs,
          diff_entries: diff_entries
        }
      end

      def design_docs_for(corpus_case, revision)
        paths = Array(corpus_case["design_document_paths"]).presence || Array(manifest_design_document_paths)
        paths.first(MAX_DESIGN_DOCS).filter_map do |path|
          content = client&.file_content(project.full_name, path: path, ref: revision)
          next if content.blank?

          { path: path, content: sanitized_prompt_text(content, max_length: MAX_DESIGN_DOC_LENGTH) }
        rescue GithubClient::Error
          nil
        end
      end

      def manifest_design_document_paths
        @manifest_design_document_paths ||= begin
          document = YAML.safe_load_file(@evaluation.corpus.resolved_path, aliases: true) || {}
          document.is_a?(Hash) ? Array(document["design_document_paths"]) : []
        end
      end

      def diff_entries_for(base_sha, head_sha)
        comparison = client&.compare_summary(project.full_name, base_sha, head_sha)
        return if comparison.nil?

        files = Array(comparison[:files]).first(MAX_FILES)
        return [] if files.empty?

        files.map do |file|
          {
            filename: sanitized_prompt_text(file[:filename]),
            status: sanitized_prompt_text(file[:status]),
            additions: file[:additions],
            deletions: file[:deletions],
            patch_excerpt: patch_for(file)
          }.compact
        end
      rescue GithubClient::Error
        nil
      end

      def upsert_run(corpus_case, verdict, failure_reason, model, cost_cents)
        run = @evaluation.runs.find_or_initialize_by(case_id: corpus_case.fetch("id"))
        run.update!(
          verdict: verdict,
          failure_reason: failure_reason,
          reviewer_model: model.to_s,
          reviewer_run_id: run.reviewer_run_id.presence || "shadow-eval-#{@evaluation.id}-#{corpus_case.fetch('id')}",
          prompt_digest: prompt_digest,
          cost_cents: cost_cents,
          recorded_at: Time.current
        )
      end

      def complete_or_fail(executed, failed)
        if failed.zero?
          @evaluation.update!(status: "completed", completed_at: Time.current, last_failure_reason: nil)
        else
          @evaluation.update!(status: "failed", last_failure_reason: "#{failed} case(s) ended without an evaluated reviewer verdict")
        end
        log_executed(executed, failed)
        Result.new(success: true, error: nil, evaluation: @evaluation, executed: executed, failed: failed)
      end

      def prompt_digest
        require "digest"
        Digest::SHA256.hexdigest(ReviewerLlm::PROMPT)
      end

      def project
        @project ||= @evaluation.project
      end

      def client
        @client ||= project.client
      end

      def log_executed(executed, failed)
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_executed",
          project_id: project.id,
          shadow_evaluation_id: @evaluation.id,
          executed_count: executed,
          failed_count: failed
        )
      end

      def patch_for(file)
        patch = file[:patch].to_s
        return if patch.blank?

        sanitized_prompt_text(patch, max_length: MAX_PATCH_LENGTH, omission: "\n[truncated]")
      end

      GITHUB_TOKEN_IN_TEXT = /\b(?:ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|gh[oushr]_[A-Za-z0-9]{36,})\b/
      SECRET_PATTERNS = (StyleGuides::CollectCodeSamples::SECRET_PATTERNS + [ GITHUB_TOKEN_IN_TEXT ]).freeze

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

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil, executed: 0, failed: 0)
      end
    end
  end
end
