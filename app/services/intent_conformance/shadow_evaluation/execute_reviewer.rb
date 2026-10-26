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
    #
    # Runs inside ShadowEvaluationExecuteJob (#4642): it refreshes the
    # execution heartbeat before every case, honors a cooperative
    # cancellation between cases (collected evidence survives and no
    # unevaluated case is fabricated), and maps the pass to a terminal
    # completed/partial/failed/cancelled state computed from persisted runs.
    # @spec INTENT-CONFORMANCE-ROLLOUT-006
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecuteReviewer
      Result = Data.define(:success, :error, :evaluation, :executed, :failed, :cancelled, :busy) do
        def success? = success
        def cancelled? = cancelled
        def busy? = busy
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
        identity_error = reviewer_identity_error
        return failure(identity_error) if identity_error

        unless try_lock!
          Rails.logger.info(
            message: "intent_conformance.shadow_evaluation_execute_lock_held",
            project_id: @evaluation.project_id,
            shadow_evaluation_id: @evaluation.id
          )
          return busy_failure("reviewer execution is already in progress for this evaluation; retry once it finishes")
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
      # possible (#4598 review). Only the lock holder mutates lifecycle
      # state, so a duplicate recovery enqueue can never fold a live pass.
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
        mark_running!
        executed = 0
        failed = 0

        @evaluation.corpus.cases.each do |corpus_case|
          break if cancellation_requested?
          next if evaluated_run_for(corpus_case.fetch("id"))

          heartbeat!
          verdict, failure_reason, model, cost = review_case(corpus_case)
          upsert_run(corpus_case, verdict, failure_reason, model, cost)
          verdict == NOT_EVALUATED ? failed += 1 : executed += 1
        end

        finalize(executed: executed, failed: failed, cancelled: cancellation_requested?)
      rescue ShadowEvaluationCorpus::MissingManifest => error
        @evaluation.update!(status: "failed", last_failure_reason: error.message)
        failure(error.message)
      end

      def mark_running!
        @evaluation.update!(status: "running", execute_started_at: Time.current, execution_heartbeat_at: Time.current)
      end

      def heartbeat!
        @evaluation.update!(execution_heartbeat_at: Time.current)
      end

      # @spec INTENT-CONFORMANCE-ROLLOUT-011 — cooperative stop between
      # cases. Collected runs are untouched and cases never reached stay
      # without a run row rather than being fabricated as results. Read the
      # flag with a targeted query instead of #reload so the evaluation's
      # memoized corpus and project associations survive the pass.
      def cancellation_requested?
        IntentConformanceShadowEvaluation.where(id: @evaluation.id).pick(:cancel_requested_at).present?
      end

      # Terminal state is recomputed from persisted runs, never from the
      # pass-local counters, so an interrupted or resumed pass converges on
      # the same answer: every case evaluated → completed; some evaluated →
      # partial; none → failed; operator stop wins only while work remains.
      def finalize(executed:, failed:, cancelled:)
        remaining = remaining_case_ids.length
        evaluated = @evaluation.corpus.case_ids.length - remaining
        status =
          if remaining.zero?
            "completed"
          elsif cancelled
            "cancelled"
          elsif evaluated.positive?
            "partial"
          else
            "failed"
          end
        reason = failure_reason_for(status, remaining, failed)
        @evaluation.update!(status: status, completed_at: status == "completed" ? Time.current : nil, last_failure_reason: reason)
        log_executed(executed, failed, cancelled)
        Result.new(success: true, error: nil, evaluation: @evaluation, executed: executed, failed: failed,
          cancelled: cancelled && remaining.positive?, busy: false)
      end

      def remaining_case_ids
        evaluated_ids = @evaluation.runs.evaluated.pluck(:case_id).index_with { true }
        @evaluation.corpus.case_ids.reject { |case_id| evaluated_ids[case_id] }
      end

      def failure_reason_for(status, remaining, failed)
        case status
        when "completed" then nil
        when "cancelled" then "cancelled by operator — #{remaining} case(s) left without an evaluated reviewer verdict"
        when "partial" then "#{remaining} case(s) ended without an evaluated reviewer verdict"
        else "#{failed.positive? ? failed : remaining} case(s) ended without an evaluated reviewer verdict"
        end
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

      # A report identifies a specific reviewer configuration, so execution
      # must neither substitute ReviewerLlm's default model nor run a prompt
      # whose identity differs from the manifest's frozen provenance.
      def reviewer_identity_error
        return "corpus manifest reviewer model is required" if reviewer_model.blank?
        return "corpus manifest reviewer prompt version is not executable" unless reviewer_prompt_version == ReviewerLlm::PROMPT_VERSION
        "corpus manifest reviewer prompt digest does not match the executable prompt" unless reviewer_prompt_digest == prompt_digest
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

      def log_executed(executed, failed, cancelled)
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_executed",
          project_id: project.id,
          shadow_evaluation_id: @evaluation.id,
          executed_count: executed,
          failed_count: failed,
          cancelled: cancelled
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
        Result.new(success: false, error: message, evaluation: nil, executed: 0, failed: 0, cancelled: false, busy: false)
      end

      def busy_failure(message)
        Result.new(success: false, error: message, evaluation: nil, executed: 0, failed: 0, cancelled: false, busy: true)
      end
    end
  end
end
