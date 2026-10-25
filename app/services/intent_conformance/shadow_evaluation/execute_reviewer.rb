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
    # execution. Runs from the background ExecuteJob (#4642): it honors a
    # requested cancellation between cases (preserving collected evidence,
    # never fabricating unevaluated results), records a per-case heartbeat
    # for stranded-worker recovery, and reports a partial state when only
    # some cases evaluated.
    # @spec INTENT-CONFORMANCE-ROLLOUT-006
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecuteReviewer
      Result = Data.define(:success, :error, :evaluation, :executed, :failed, :cancelled) do
        def success? = success
        def cancelled? = cancelled
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

      # A report identifies a specific reviewer configuration, so execution
      # must neither substitute ReviewerLlm's default model nor run a prompt
      # whose identity differs from the manifest's frozen provenance. Shared
      # by the enqueue path so prerequisite identity failures are answered
      # in the originating HTTP response (#4642).
      def self.identity_error(evaluation)
        identity = evaluation.corpus.reviewer_identity
        if identity.fetch("model").blank?
          "corpus manifest reviewer model is required"
        elsif identity.fetch("prompt_version") != ReviewerLlm::PROMPT_VERSION
          "corpus manifest reviewer prompt version is not executable"
        elsif identity.fetch("prompt_sha256") != prompt_digest
          "corpus manifest reviewer prompt digest does not match the executable prompt"
        end
      end

      def self.prompt_digest
        require "digest"
        Digest::SHA256.hexdigest(ReviewerLlm::PROMPT)
      end

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless @evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless @evaluation.corpus.matches_recorded_digest?
        return failure("no corpus cases to evaluate") if @evaluation.corpus.case_ids.empty?
        identity_error = self.class.identity_error(@evaluation)
        return failure(identity_error) if identity_error

        unless try_lock!
          Rails.logger.info(
            message: "intent_conformance.shadow_evaluation_execute_lock_held",
            project_id: @evaluation.project_id,
            shadow_evaluation_id: @evaluation.id
          )
          return failure("reviewer execution is already in progress for this evaluation; retry once it finishes")
        end

        begin
          return cancel! if cancellation_requested?
          execute_cases
        ensure
          unlock!
        end
      rescue ShadowEvaluationCorpus::MissingManifest => error
        failure(error.message)
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
        @evaluation.update!(status: "executing", execute_started_at: Time.current, execute_heartbeat_at: Time.current)
        executed = 0
        failed = 0

        @evaluation.corpus.cases.each do |corpus_case|
          return cancel! if cancellation_requested?

          next if evaluated_run_for(corpus_case.fetch("id"))

          verdict, failure_reason, model, cost = review_case(corpus_case)
          upsert_run(corpus_case, verdict, failure_reason, model, cost)
          heartbeat!
          verdict == NOT_EVALUATED ? failed += 1 : executed += 1
        end

        complete_or_fail(executed, failed)
      rescue ShadowEvaluationCorpus::MissingManifest => error
        @evaluation.update!(status: "failed", last_failure_reason: error.message)
        failure(error.message)
      end

      # Per-case heartbeat (#4642): a stale heartbeat with a free execution
      # lock is the signal that a worker died mid-run, so recovery and
      # re-enqueue can distinguish it from a merely slow provider call.
      def heartbeat!
        @evaluation.update_columns(execute_heartbeat_at: Time.current)
      end

      # Cooperative cancellation (#4642): an authorized CancelExecution sets
      # the flag; the loop observes it at each case boundary and stops with
      # the terminal cancelled state. Recorded runs are preserved exactly as
      # executed and unvisited cases stay without a verdict — nothing is
      # fabricated for them. Read through a dedicated query: reloading the
      # in-memory evaluation would drop its association cache mid-loop.
      def cancellation_requested?
        IntentConformanceShadowEvaluation.where(id: @evaluation.id).pick(:cancel_requested_at).present?
      end

      def cancel!
        @evaluation.update!(
          status: "cancelled",
          last_failure_reason: "execution cancelled by operator; collected reviewer evidence is preserved"
        )
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_execute_cancelled",
          project_id: @evaluation.project_id,
          shadow_evaluation_id: @evaluation.id
        )
        Result.new(success: true, error: nil, evaluation: @evaluation, executed: 0, failed: 0, cancelled: true)
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
          verification: "No verification evidence was available.",
          model: reviewer_model
        )
        return [ NOT_EVALUATED, result.status.to_s, nil, 0 ] unless result.ok?
        return [ NOT_EVALUATED, "reviewer_model_mismatch", result.model, result.cost_cents ] unless result.model == reviewer_model

        [ result.validated[:outcome], nil, result.model, result.cost_cents ]
      end

      def reviewer_identity
        @reviewer_identity ||= @evaluation.corpus.reviewer_identity
      end

      def reviewer_model
        reviewer_identity.fetch("model")
      end

      def reviewer_prompt_version
        reviewer_identity.fetch("prompt_version")
      end

      def reviewer_prompt_digest
        reviewer_identity.fetch("prompt_sha256")
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

      # Terminal state reflects ALL persisted evidence, not just this pass:
      # completed means every corpus case holds an evaluated verdict; partial
      # means at least one does (earlier or this pass) while others do not;
      # failed means nothing evaluated. A retry after a partial pass never
      # re-spends on completed cases, so the retained verdicts keep counting.
      def complete_or_fail(executed, failed)
        unevaluated = @evaluation.corpus.case_ids.count { |case_id| evaluated_run_for(case_id).nil? }
        if unevaluated.zero?
          @evaluation.update!(status: "completed", completed_at: Time.current, last_failure_reason: nil)
        elsif @evaluation.runs.where.not(verdict: NOT_EVALUATED).exists?
          @evaluation.update!(status: "partial", completed_at: nil, last_failure_reason: "#{unevaluated} case(s) ended without an evaluated reviewer verdict")
        else
          @evaluation.update!(status: "failed", completed_at: nil, last_failure_reason: "#{unevaluated} case(s) ended without an evaluated reviewer verdict")
        end
        log_executed(executed, failed)
        Result.new(success: true, error: nil, evaluation: @evaluation, executed: executed, failed: failed, cancelled: false)
      end

      def prompt_digest
        self.class.prompt_digest
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
        Result.new(success: false, error: message, evaluation: nil, executed: 0, failed: 0, cancelled: false)
      end
    end
  end
end
