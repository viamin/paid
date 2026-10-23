# frozen_string_literal: true

require_relative "assessment_corpus_ledger"

module FacetConfidence
  # Computes the RDR-070 outcome metrics required by the facet-confidence
  # acceptance criterion. Threshold or rubric tuning proposals stay
  # unevaluated until these measures exist; rising throughput alone never
  # justifies tuning.
  # @spec FACET-CONFIDENCE-018
  module AssessmentOutcomeReport
    # Verdicts where the assessment itself declined to decide. A failed run is
    # an operational (provider/runtime) failure, not an assessment verdict: it
    # asked no clarifying question and produced no scores, so it never enters
    # the verdict measures and is reported separately as an operational failure.
    UNDECISIVE_RUN_STATUSES = %w[clarification_needed unknown].freeze
    FAILED_RUN_STATUS = "failed"

    module_function

    def metrics(corpus_path:, ledger_path:)
      evaluation = AssessmentCorpusLedger.evaluate(corpus_path:, ledger_path:)
      latest = evaluation.to_h { |id, entry| [ id, { case: entry.fetch(:case), run: entry.fetch(:runs).last } ] }
      verdicts = latest.select { |_id, entry| entry[:run] && entry[:run].fetch("status") != FAILED_RUN_STATUS }
      assessed = verdicts.length

      {
        corpus_version: AssessmentCorpusLedger.corpus_version_of(corpus_path),
        coverage: { assessed:, total: latest.length },
        false_readiness: measure(verdicts, ->(entry) { entry.fetch(:case)["expected"]["readiness"] == "not_ready" }) do |entry|
          run_ready?(entry.fetch(:case), entry.fetch(:run))
        end,
        unnecessary_clarification: measure(verdicts, ->(entry) { entry.fetch(:case)["expected"]["status"] == "completed" }) do |entry|
          UNDECISIVE_RUN_STATUSES.include?(entry.fetch(:run).fetch("status"))
        end,
        human_corrections: corrections_measure(evaluation),
        assessment_cost_cents: evaluation.values.sum { |entry| entry.fetch(:runs).sum { |run| run.fetch("cost_cents") } },
        downstream_rework: rework_measure(evaluation),
        band_divergences: measure(verdicts, ->(_entry) { true }) { |entry| diverges?(entry.fetch(:case), entry.fetch(:run)) },
        operational_failures: measure(latest, ->(_entry) { true }) { |entry| entry.fetch(:run).fetch("status") == FAILED_RUN_STATUS },
        tuning_gate: assessed == latest.length ? "metrics_required" : "blocked_incomplete_coverage"
      }
    end

    def compile(corpus_path:, ledger_path:)
      metrics = metrics(corpus_path:, ledger_path:)
      coverage = metrics.fetch(:coverage)
      raise AssessmentCorpusLedger::PendingOperatorInput, "pending operator input: every corpus case needs a non-failed assessment verdict" unless coverage[:assessed] == coverage[:total]

      format(WORKSHEET_TEMPLATE,
        corpus_version: metrics.fetch(:corpus_version),
        assessed: coverage[:assessed],
        total: coverage[:total],
        false_readiness: count_cell(metrics.fetch(:false_readiness)),
        unnecessary_clarification: count_cell(metrics.fetch(:unnecessary_clarification)),
        human_corrections: count_cell(metrics.fetch(:human_corrections)),
        cost: metrics.fetch(:assessment_cost_cents),
        rework_events: metrics.fetch(:downstream_rework)[:events],
        rework_cost: metrics.fetch(:downstream_rework)[:cost_cents],
        divergences: count_cell(metrics.fetch(:band_divergences)),
        operational_failures: count_cell(metrics.fetch(:operational_failures)))
    end

    WORKSHEET_TEMPLATE = <<~WORKSHEET
      # RDR-070 Facet-Confidence Assessment Outcome Worksheet

      Corpus: %{corpus_version} — coverage %{assessed} / %{total} cases.

      | Measure | Result | Ledger evidence |
      | --- | --- | --- |
      | False readiness | %{false_readiness} | expected readiness band vs assessment_run |
      | Unnecessary clarification | %{unnecessary_clarification} | expected decisive outcome vs assessment_run status |
      | Human corrections | %{human_corrections} | correction events |
      | Assessment cost | %{cost} cents | assessment_run.cost_cents |
      | Downstream rework | %{rework_events} events / %{rework_cost} cents | rework events |
      | Band divergences | %{divergences} | expected bands vs assessment_run scores |
      | Operational failures | %{operational_failures} | assessment_run status failed |

      ## Tuning gate

      Threshold or rubric tuning proposals must cite the outcome metrics above;
      a throughput increase alone never justifies tuning. Tuning before the
      measures exist stays blocked by `blocked_incomplete_coverage`.
    WORKSHEET

    def run_ready?(corpus_case, run)
      return false unless run.fetch("status") == "completed"

      thresholds = corpus_case.fetch("thresholds")
      run.fetch("intent_score") >= thresholds.fetch("intent") && run.fetch("technical_score") >= thresholds.fetch("technical")
    end

    def diverges?(corpus_case, run)
      expected = corpus_case.fetch("expected")
      thresholds = corpus_case.fetch("thresholds")
      expected.fetch("intent_band") != band(run["intent_score"], thresholds.fetch("intent")) ||
        expected.fetch("technical_band") != band(run["technical_score"], thresholds.fetch("technical"))
    end

    def band(score, threshold)
      return "unknown" unless score.is_a?(Integer)

      score < threshold ? "below_threshold" : "at_or_above_threshold"
    end

    def measure(entries, applicable)
      applicable_entries = entries.values.select { |entry| entry[:run] && applicable.call(entry) }
      matched = applicable_entries.select { |entry| yield(entry) }
      { count: matched.length, rate: rate(matched.length, applicable_entries.length),
        cases: matched.map { |entry| entry.fetch(:case).fetch("id") } }
    end

    def corrections_measure(evaluation)
      corrections = evaluation.values.select { |entry| entry.fetch(:corrections).any? }
      { count: evaluation.values.sum { |entry| entry.fetch(:corrections).length },
        rate: rate(corrections.length, evaluation.length),
        cases: corrections.map { |entry| entry.fetch(:case).fetch("id") } }
    end

    def rework_measure(evaluation)
      rework = evaluation.values.select { |entry| entry.fetch(:rework).any? }
      { events: evaluation.values.sum { |entry| entry.fetch(:rework).length },
        cost_cents: evaluation.values.sum { |entry| entry.fetch(:rework).sum { |event| event.fetch("cost_cents") } },
        cases: rework.map { |entry| entry.fetch(:case).fetch("id") } }
    end

    def rate(count, denominator)
      return "not established" if denominator.zero?

      format("%.1f%% (%d / %d)", count * 100.0 / denominator, count, denominator)
    end

    def count_cell(measure)
      "#{measure.fetch(:count)} (#{measure.fetch(:rate)})"
    end
  end
end
