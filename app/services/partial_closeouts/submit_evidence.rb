# frozen_string_literal: true

module PartialCloseouts
  # Persists a submission against one human-gap occurrence. Structural checks
  # happen here; semantic acceptance remains a bounded acceptance audit through
  # agent_harness, never a URL/comment/green run shortcut.
  # @spec PARTIAL-CLOSEOUT-030
  class SubmitEvidence
    Result = Data.define(:success, :error, :outcome) do
      def success? = success
      def message = error
    end

    KINDS = %w[artifact link evaluation run report].freeze
    OUTCOMES = %w[submitted sufficient insufficient stale unavailable].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, prerequisite_id:, kind:, reference:, revision:, explanation:)
      @issue, @actor, @prerequisite_id = issue, actor, prerequisite_id.to_s
      @kind, @reference, @revision, @explanation = kind.to_s, reference.to_s.strip, revision.to_s.strip, explanation.to_s.strip
    end

    def call
      return failure("Select a supported evidence type.") unless KINDS.include?(kind)
      return failure("Evidence reference, revision, and explanation are required.") if [ reference, revision, explanation ].any?(&:blank?)

      issue.with_lock do
        run, index, gap = matching_gap
        return failure("That prerequisite is no longer current; refresh the Inbox item.") unless gap

        outcome, reasoning = disposition_for
        submission = {
          "id" => SecureRandom.uuid, "kind" => kind, "reference" => reference, "revision" => revision,
          "explanation" => explanation, "actor_id" => actor.id, "submitted_at" => Time.current.iso8601,
          "outcome" => outcome, "reasoning" => reasoning
        }
        updated_gap = gap.merge("evidence_submissions" => Array(gap["evidence_submissions"]) + [ submission ])
        gaps = run.reconciliation.fetch("gaps", {}).deep_stringify_keys.merge(index.to_s => updated_gap)
        run.update!(reconciliation: run.reconciliation.deep_stringify_keys.merge("gaps" => gaps))
        refresh_notification!(run)
        Result.new(success: true, error: nil, outcome: outcome)
      end
    rescue ActiveRecord::RecordInvalid => error
      failure(error.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :issue, :actor, :prerequisite_id, :kind, :reference, :revision, :explanation

    def matching_gap
      latest_runs.each do |run|
        run.reconciliation.fetch("gaps", {}).deep_stringify_keys.each do |index, gap|
          return [ run, index, gap ] if gap["kind"] == "human" && "#{run.id}:#{index}" == prerequisite_id
        end
      end
      [ nil, nil, nil ]
    end

    def latest_runs
      issue.agent_runs.where("reconciliation ? 'gaps'").order(id: :desc).to_a
    end

    def disposition_for
      return [ "unavailable", "The referenced URL is not an HTTP(S) durable link." ] if kind == "link" && !reference.match?(%r{\Ahttps?://})
      return [ "stale", "The cited evaluation belongs to another project or its report is no longer current." ] if kind == "evaluation" && stale_evaluation?
      return [ "insufficient", "The solo evaluation report is attached, but its weaker assurance and missing production measures do not satisfy acceptance." ] if kind == "evaluation"

      [ "submitted", "Structural evidence is recorded. Request the bounded acceptance audit for semantic validation; this submission does not release the prerequisite." ]
    end

    def stale_evaluation?
      evaluation = IntentConformanceShadowEvaluation.find_by(id: reference)
      evaluation.nil? || evaluation.project_id != issue.project_id || evaluation.report.blank? || !evaluation.completed?
    end

    def refresh_notification!(run)
      gaps = run.reconciliation.fetch("gaps", {}).values
      pending = gaps.select { |gap| gap["kind"] == "human" }
      Notifications::Publish.call(account: issue.project.account, subject: issue,
        source: PREREQUISITE_NOTIFICATION_SOURCE, severity: :error, blocking: true,
        title: pending.one? ? "#{pending.first['criterion']} needs operator action" : "#{pending.size} partial-closeout prerequisites need operator action",
        description: pending.map { |gap| description_for(run, gap) }.join("\n"))
    end

    def description_for(run, gap)
      latest = Array(gap["evidence_submissions"]).last
      state = latest ? "Evidence #{latest['outcome']}: #{latest['reasoning']}" : gap["next_step"].to_s
      "#{gap['criterion']} (#{run.id}:#{run.reconciliation.fetch('gaps', {}).key(gap)}): #{state}"
    end

    def failure(message) = Result.new(success: false, error: message, outcome: nil)
  end
end
