# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Compiles the reproducible closeout-evaluation report from the persisted
    # record: exact originating-closeout and corpus identities, the frozen
    # reference judgments, the frozen expected bands, per-case divergences and
    # citation compliance, aggregate measures, and provenance (including the
    # sole reference judge). The report is retained on the evaluation and is
    # evidence only: it never closes the source issue, enables delivery, or
    # changes the 80/80 defaults.
    # @spec FACET-CONFIDENCE-021
    class CompileReport
      Result = Data.define(:success, :error, :report, :markdown) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("the report requires a frozen reference set; freeze the judgments first") unless @evaluation.answers_visible?

        report = build_report
        markdown = render_markdown(report)
        @evaluation.update!(report: report, report_markdown: markdown)
        Result.new(success: true, error: nil, report: report, markdown: markdown)
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation

      def build_report
        entries = case_entries
        {
          "evaluation_id" => @evaluation.id,
          "originating_closeout" => {
            "work_item" => @evaluation.issue.github_number,
            "project" => @evaluation.project.full_name,
            "source_revision" => @evaluation.source_revision
          },
          "provenance" => {
            "corpus_path" => @evaluation.corpus_path,
            "corpus_digest" => @evaluation.corpus_digest,
            "corpus_digest_matches_current" => @evaluation.corpus.matches_recorded_digest?,
            "corpus_version" => @evaluation.corpus_version,
            "rubric_version" => @evaluation.rubric_version,
            "model_version" => @evaluation.model_version,
            "judge" => @evaluation.created_by.email,
            "started_at" => @evaluation.created_at.iso8601,
            "labels_frozen_at" => @evaluation.labels_frozen_at&.iso8601
          },
          "cases" => entries,
          "post_unblinding_revisions" => stored_revisions,
          "measures" => measures(entries),
          "policy" => "reference judgments are policy assessments, not calibrated probabilities; " \
            "this report neither closes the source issue, enables delivery, nor changes the 80/80 defaults"
        }
      end

      def case_entries
        # Reload: the calling request or spec may hold a memoized evaluation
        # whose association targets predate the judgments.
        labels = @evaluation.labels.reload.index_by(&:case_id)
        @evaluation.corpus.cases.map { |corpus_case| case_entry(corpus_case, labels[corpus_case.fetch("id")]) }
      end

      def stored_revisions
        @evaluation.report.fetch("post_unblinding_revisions", {})
      end

      def case_entry(corpus_case, label)
        expected = corpus_case.fetch("expected")
        judgment = label&.labeled? ? judgment_of(label) : nil
        {
          "case_id" => corpus_case.fetch("id"),
          "shape" => corpus_case["shape"],
          "judgment" => judgment,
          "expected" => expected.slice("status", "intent_band", "technical_band", "readiness"),
          "divergences" => divergences(judgment, expected),
          "citation_compliance" => citation_compliance(judgment, expected)
        }
      end

      def judgment_of(label)
        {
          "verdict" => label.verdict, "intent_band" => label.intent_band, "technical_band" => label.technical_band,
          "readiness" => label.readiness, "cited_evidence_reference" => label.cited_evidence_reference,
          "reason" => label.reason
        }
      end

      def divergences(judgment, expected)
        return [] if judgment.nil?

        [].tap do |divergences|
          divergences << "verdict" if judgment.fetch("verdict") != expected.fetch("status")
          divergences << "intent_band" if judgment.fetch("intent_band") != expected.fetch("intent_band")
          divergences << "technical_band" if judgment.fetch("technical_band") != expected.fetch("technical_band")
          divergences << "readiness" if judgment.fetch("readiness") != expected.fetch("readiness")
        end
      end

      def citation_compliance(judgment, expected)
        return nil if judgment.nil?

        cited = judgment.fetch("cited_evidence_reference")
        [].tap do |violations|
          violations << "must_cite" if expected["must_cite"].present? && !expected["must_cite"].include?(cited)
          violations << "must_not_cite" if expected["must_not_cite"].to_a.include?(cited)
        end
      end

      def measures(entries)
        {
          "verdict_divergences" => measure(entries, "verdict"),
          "intent_band_divergences" => measure(entries, "intent_band"),
          "technical_band_divergences" => measure(entries, "technical_band"),
          "readiness_divergences" => measure(entries, "readiness"),
          "citation_violations" => {
            "count" => entries.count { |entry| entry.fetch("citation_compliance").to_a.any? },
            "cases" => entries.select { |entry| entry.fetch("citation_compliance").to_a.any? }
              .map { |entry| entry.fetch("case_id") }
          }
        }
      end

      def measure(entries, field)
        matched = entries.select { |entry| entry.fetch("divergences").include?(field) }
        { "count" => matched.length, "cases" => matched.map { |entry| entry.fetch("case_id") } }
      end

      def render_markdown(report)
        format(WORKSHEET_TEMPLATE,
          work_item: report.fetch("originating_closeout").fetch("work_item"),
          project_name: report.fetch("originating_closeout").fetch("project"),
          source_revision: report.fetch("originating_closeout").fetch("source_revision").presence || "not recorded",
          corpus_version: report.dig("provenance", "corpus_version"),
          corpus_digest: report.dig("provenance", "corpus_digest"),
          rubric_version: report.dig("provenance", "rubric_version"),
          model_version: report.dig("provenance", "model_version"),
          judge: report.dig("provenance", "judge"),
          frozen_at: report.dig("provenance", "labels_frozen_at"),
          measures: measures_table(report.fetch("measures")),
          cases: cases_table(report.fetch("cases")),
          revisions: revisions_table(report.fetch("post_unblinding_revisions")))
      end

      def measures_table(measures)
        measures.map { |name, measure| format("| %s | %d (%s) |", name.tr("_", " "), measure.fetch("count"), measure.fetch("cases").join(", ")) }.join("\n")
      end

      def cases_table(entries)
        entries.map do |entry|
          judgment = entry.fetch("judgment") || {}
          format("| %s | %s | %s | %s | %s | %s | %s |",
            entry.fetch("case_id"), entry.fetch("shape"),
            judgment["verdict"], judgment["intent_band"],
            judgment["technical_band"], judgment["readiness"],
            divergences_cell(entry))
        end.join("\n")
      end

      def divergences_cell(entry)
        parts = entry.fetch("divergences").dup
        parts += entry.fetch("citation_compliance").to_a.map { |violation| "citation:#{violation}" }
        parts.empty? ? "aligned" : parts.join(", ")
      end

      def revisions_table(revisions)
        return "No post-unblinding corrections recorded." if revisions.empty?

        revisions.flat_map do |case_id, entries|
          entries.map do |revision|
            format("| %s | %s | %s | %s | %s | %s |", case_id, revision.fetch("verdict"),
              revision.fetch("intent_band"), revision.fetch("technical_band"), revision.fetch("readiness"),
              revision.fetch("reason"))
          end
        end.join("\n")
      end

      WORKSHEET_TEMPLATE = <<~WORKSHEET
        # RDR-070 Facet-Confidence Closeout Evaluation Report

        Originating closeout: #%{work_item} (%{project_name}) · source revision %{source_revision}.
        Corpus %{corpus_version} (digest %{corpus_digest}) · rubric %{rubric_version} · model %{model_version}.
        Reference judge %{judge} · reference set frozen %{frozen_at}.

        ## Measures (frozen judgments vs frozen expectations)

        | Measure | Count (cases) |
        | --- | --- |
        %{measures}

        ## Per-case judgments vs frozen expectations

        | Case | Shape | Verdict | Intent band | Technical band | Readiness | Divergences |
        | --- | --- | --- | --- | --- | --- | --- |
        %{cases}

        ## Post-unblinding corrections (original labels remain scored)

        | Case | Verdict | Intent band | Technical band | Readiness | Reason |
        | --- | --- | --- | --- | --- | --- |
        %{revisions}

        Reference judgments are policy assessments, not calibrated probabilities.
        This report neither closes the source issue, enables delivery, nor changes the 80/80 defaults.
      WORKSHEET
    end
  end
end
