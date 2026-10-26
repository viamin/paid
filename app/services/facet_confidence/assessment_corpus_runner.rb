# frozen_string_literal: true

module FacetConfidence
  # Executes the frozen RDR-070 assessment corpus through the shipped facet
  # assessment path and records the runs in the repository-visible corpus
  # ledger, so the measured outcome metrics exist without hand-transcribed
  # scores.
  #
  # A run is recorded only when the provider served the corpus's pinned rubric
  # model: the shipped ledger refuses to attribute a run from another model to
  # the frozen corpus, and this runner refuses before the event is written.
  # Nothing here changes thresholds, releases work, or touches the readiness
  # path.
  #
  # @spec FACET-CONFIDENCE-022
  class AssessmentCorpusRunner
    DEFAULT_CORPUS_PATH = "docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml"
    DEFAULT_LEDGER_PATH = "docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl"

    Result = Data.define(:success, :error, :recorded, :refused, :report) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(project:, corpus_path: DEFAULT_CORPUS_PATH, ledger_path: DEFAULT_LEDGER_PATH, agent_harness: AgentHarness)
      @project = project
      @corpus_path = corpus_path
      @ledger_path = ledger_path
      @agent_harness = agent_harness
    end

    def call
      outcomes = corpus.cases.map { |corpus_case| evaluate(corpus_case) }
      Result.new(success: true, error: nil, recorded: outcomes.select { |outcome| outcome.fetch(:recorded) },
        refused: outcomes.reject { |outcome| outcome.fetch(:recorded) }, report: compiled_report)
    rescue FacetConfidence::Corpus::MissingManifest, AssessmentCorpusLedger::InvalidLedger => error
      Result.new(success: false, error: error.message, recorded: [], refused: [], report: nil)
    end

    private

    attr_reader :project, :corpus_path, :ledger_path, :agent_harness

    def corpus = @corpus ||= FacetConfidence::Corpus.new(path: corpus_path)

    def evaluate(corpus_case)
      outcome = AssessmentCorpusCase.call(corpus_case: corpus_case, project: project, agent_harness: agent_harness)
      record(corpus_case, outcome)
    end

    def record(corpus_case, outcome)
      mismatch = model_mismatch(corpus_case, outcome)
      return refusal(corpus_case, outcome, mismatch) if mismatch

      AssessmentCorpusLedger.append!(ledger_path: ledger_path, corpus_path: corpus_path,
        event: event_for(corpus_case, outcome))
      { recorded: true, case_id: outcome.case_id, outcome: outcome, error: nil }
    rescue AssessmentCorpusLedger::InvalidLedger => error
      refusal(corpus_case, outcome, error.message)
    end

    def model_mismatch(corpus_case, outcome)
      return nil if outcome.served_model.blank?
      return nil if outcome.served_model == corpus_case.fetch("model_version")

      "provider served model #{outcome.served_model}; the frozen corpus pins #{corpus_case.fetch('model_version')}"
    end

    def refusal(corpus_case, outcome, reason)
      { recorded: false, case_id: corpus_case.fetch("id"), outcome: outcome, error: reason }
    end

    def event_for(corpus_case, outcome)
      {
        # A unique event id per attempt keeps the shipped replay guard the
        # reason a repeated measurement is refused, instead of the event-id
        # uniqueness check.
        "event_id" => "run-#{corpus_case.fetch('id')}-r#{outcome.input_revision}-#{SecureRandom.hex(4)}",
        "recorded_at" => Time.current.utc.iso8601,
        "type" => "assessment_run",
        "case_id" => corpus_case.fetch("id"),
        "rubric_version" => corpus_case.fetch("rubric_version"),
        "model_version" => corpus_case.fetch("model_version"),
        "status" => outcome.status,
        "input_revision" => outcome.input_revision,
        "intent_score" => outcome.status == "completed" ? outcome.intent_score : nil,
        "technical_score" => outcome.technical_score,
        "evidence_references" => outcome.evidence_references,
        "cost_cents" => outcome.cost_cents
      }
    end

    def compiled_report
      AssessmentOutcomeReport.compile(corpus_path: corpus_path, ledger_path: ledger_path)
    rescue AssessmentCorpusLedger::PendingOperatorInput => error
      "pending operator input: #{error.message}"
    end
  end
end
