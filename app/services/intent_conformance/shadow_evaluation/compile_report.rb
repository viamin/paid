# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Compiles the reproducible evaluation report from the persisted record:
    # exact case/rubric/model/prompt/design identities, original reference
    # labels, appended revisions, reviewer verdicts, confusion counts, false
    # alarms, missed drift, uncertainty handling, cost, and provenance
    # (including the policy and declared maintainer next to every measure).
    # Missing production measures stay explicitly not established. No
    # promotion decision is emitted and nothing here attests issue
    # completion or enables enforcement.
    # @spec INTENT-CONFORMANCE-ROLLOUT-008
    class CompileReport
      Result = Data.define(:success, :error, :report, :markdown) do
        def success? = success
      end

      VERDICTS = IntentConformance::ShadowEvaluationPolicy::LABELS

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("the report requires executed reviewer runs; freeze labels and execute the reviewer first") unless @evaluation.runs.exists?

        report = build_report
        markdown = render_markdown(report)
        @evaluation.update!(report: report, report_markdown: markdown)
        attach_to_originating_closeout
        Result.new(success: true, error: nil, report: report, markdown: markdown)
      end

      private

      attr_reader :evaluation

      # A completed solo report is durable evidence for the originating
      # closeout, but its own report records weaker assurance and missing
      # production measures. SubmitEvidence therefore records it as
      # insufficient rather than manufacturing acceptance or releasing work.
      # @spec PARTIAL-CLOSEOUT-030
      def attach_to_originating_closeout
        issue = evaluation.originating_issue
        return unless issue

        issue.agent_runs.where("reconciliation ? 'gaps'").order(id: :desc).each do |run|
          run.reconciliation.fetch("gaps", {}).each do |index, gap|
            next unless gap["kind"] == "human"

            PartialCloseouts::SubmitEvidence.call(issue:, actor: evaluation.created_by,
              prerequisite_id: "#{run.id}:#{index}", kind: "evaluation", reference: evaluation.id.to_s,
              revision: evaluation.manifest_digest,
              explanation: "RDR-067 solo-maintainer evaluation report #{evaluation.id}")
          end
        end
      end

      def build_report
        # Reload: the calling request or spec may hold a memoized evaluation
        # whose association targets predate revisions and runs.
        labels = @evaluation.labels.reload.index_by(&:case_id)
        runs = @evaluation.runs.reload.index_by(&:case_id)
        corpus = @evaluation.corpus
        {
          "evaluation_id" => @evaluation.id,
          "policy" => @evaluation.policy,
          "solo_maintainer" => @evaluation.solo_maintainer&.email,
          "assurance_limits" => "solo reference set: no independence, no tie-break; strictly weaker evidence than the team policy",
          "provenance" => {
            "manifest_path" => @evaluation.manifest_path,
            "manifest_commit" => @evaluation.manifest_commit,
            "manifest_digest" => @evaluation.manifest_digest,
            "manifest_digest_matches_current" => corpus.matches_recorded_digest?,
            "labels_frozen_at" => @evaluation.labels_frozen_at&.iso8601,
            "executed_at" => @evaluation.execute_started_at&.iso8601,
            "reviewer" => corpus.reviewer_identity
          },
          "cases" => corpus.cases.map { |corpus_case| case_entry(corpus_case, labels, runs) },
          "measures" => measures,
          "promotion_decision" => "not established — production measures and the explicit human promotion decision remain rollout follow-ups"
        }
      end

      def case_entry(corpus_case, labels, runs)
        label = labels[corpus_case.fetch("id")]
        run = runs[corpus_case.fetch("id")]
        {
          "case_id" => corpus_case.fetch("id"),
          "repository" => corpus_case["repository"],
          "base_sha" => corpus_case["base_sha"],
          "head_sha" => corpus_case["head_sha"],
          "approved_design_revision" => corpus_case["approved_design_revision"],
          "reference_label" => label&.outcome,
          "reference_label_reason" => label&.reason,
          "cited_design_claim" => label&.cited_design_claim,
          "revision" => label&.revised? ? { "original" => label.outcome, "revised" => label.revised_outcome, "reason" => label.revised_reason } : nil,
          "reviewer_verdict" => run&.verdict,
          "reviewer_failure_reason" => run&.failure_reason,
          "reviewer_model" => run&.reviewer_model,
          "prompt_digest" => run&.prompt_digest,
          "cost_cents" => run&.cost_cents
        }
      end

      def measures
        pairs = scored_pairs
        {
          "false_alarms" => rate(pairs, "within_scope") { |run_verdict| run_verdict != "within_scope" },
          "missed_material_drift" => rate(pairs, "material_drift") { |run_verdict| run_verdict == "within_scope" },
          "uncertainty_handling" => uncertainty_handling(pairs),
          "confusion_counts" => confusion_counts(pairs),
          "not_evaluated_cases" => pairs.count { |_case_id, label, run| run.nil? || run.not_evaluated? },
          "review_cost_cents" => review_cost_cents,
          "escaped_changes" => "not established — production follow-up required",
          "delivery_baseline" => "not established — production follow-up required",
          "rework" => "not established — production follow-up required",
          "human_time" => "not established — production follow-up required"
        }
      end

      # Original reference labels only: a revision never changes scoring.
      def scored_pairs
        labels = @evaluation.labels.where(state: "labeled").index_by(&:case_id)
        runs = @evaluation.runs.index_by(&:case_id)
        @evaluation.corpus.case_ids.filter_map do |case_id|
          label = labels[case_id]
          next unless label

          [ case_id, label, runs[case_id] ]
        end
      end

      # A missing/not-evaluated reviewer verdict never counts as agreement
      # AND never silently counts as correct: if any case of the expected
      # class lacks an evaluated verdict, the rate is not established.
      def rate(pairs, expected)
        scoped = pairs.select { |_case_id, label, _run| label.outcome == expected }
        return "not established" if scoped.empty?

        missing = scoped.count { |_case_id, _label, run| run.nil? || run.not_evaluated? }
        return "not established — #{missing} case(s) without evaluated reviewer output" if missing.positive?

        numerator = scoped.count { |_case_id, label, run| !run.not_evaluated? && yield(run.verdict) }
        format("%.1f%% (%d / %d)", numerator * 100.0 / scoped.length, numerator, scoped.length)
      end

      def uncertainty_handling(pairs)
        uncertain_references = pairs.count { |_case_id, label, _run| label.outcome == "uncertain" }
        reviewer_uncertain = pairs.count { |_case_id, _label, run| run.present? && run.verdict == "uncertain" }
        "#{uncertain_references} uncertain references, #{reviewer_uncertain} reviewer uncertain verdicts (uncertain never counts as agreement)"
      end

      # ReviewerLlm records zero when the harness omits optional cost
      # metadata. Do not present that sentinel as a measured zero-cost run.
      def review_cost_cents
        runs = @evaluation.runs.to_a.select(&:evaluated?)
        return "not established — no evaluated reviewer output" if runs.empty?
        return "not established — cost provenance is unavailable for one or more evaluated reviewer runs" if runs.any? { |run| run.cost_cents.zero? }

        runs.sum(&:cost_cents)
      end

      def confusion_counts(pairs)
        VERDICTS.to_h do |reference|
          row = VERDICTS.map do |reviewer|
            pairs.count { |_case_id, label, run| label.outcome == reference && run.present? && run.verdict == reviewer }
          end
          [ reference, row ]
        end
      end

      def render_markdown(report)
        lines = []
        lines << "# RDR-067 Solo-Maintainer Shadow Evaluation Report"
        lines << ""
        lines << "Policy: **#{report.fetch('policy')}** — maintainer #{report.fetch('solo_maintainer')}."
        lines << "Assurance limits: #{report.fetch('assurance_limits')}."
        lines << ""
        lines << "## Provenance"
        lines << ""
        provenance = report.fetch("provenance")
        lines << "- Corpus manifest: `#{provenance.fetch('manifest_path')}` @ `#{provenance.fetch('manifest_commit')}` (digest `#{provenance.fetch('manifest_digest')}`#{provenance.fetch('manifest_digest_matches_current') ? '' : ' — CHANGED since this evidence generation'})"
        lines << "- Reviewer identity: #{provenance.fetch('reviewer').slice('model', 'prompt_version').compact.map { |key, value| "#{key} #{value}" }.join(', ')}"
        lines << "- Labels frozen: #{provenance.fetch('labels_frozen_at') || 'not frozen'}; executed: #{provenance.fetch('executed_at') || 'not executed'}"
        lines << ""
        lines << "## Cases (original reference labels; revisions never rescored)"
        lines << ""
        lines << "| Case | Reference | Reviewer | Revision |"
        lines << "| --- | --- | --- | --- |"
        report.fetch("cases").each do |entry|
          revision = entry["revision"] ? "#{entry['revision'].fetch('revised')} (was #{entry['revision'].fetch('original')})" : ""
          lines << "| #{entry.fetch('case_id')} | #{entry['reference_label']} | #{entry['reviewer_verdict']} | #{revision} |"
        end
        lines << ""
        lines << "## Measures"
        lines << ""
        report.fetch("measures").each do |measure, value|
          lines << "- #{measure.to_s.humanize}: #{value.is_a?(Hash) ? value.inspect : value}"
        end
        lines << ""
        lines << "Promotion decision: #{report.fetch('promotion_decision')}."
        lines.join("\n")
      end

      def failure(message)
        Result.new(success: false, error: message, report: nil, markdown: nil)
      end
    end
  end
end
