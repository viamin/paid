# frozen_string_literal: true

require_relative "shadow_evaluation_ledger"

module IntentConformance
  # Computes the RDR-067 aggregate measures required by the rollout record.
  # @spec INTENT-CONFORMANCE-ROLLOUT-003
  module ShadowEvaluationWorksheet
    module_function

    def compile(manifest_path:, ledger_path:, manifest_commit:)
      ShadowEvaluationLedger.validate!(manifest_path:, ledger_path:, manifest_commit:)
      cases = ShadowEvaluationLedger.load_manifest(manifest_path)
      entries = ShadowEvaluationLedger.events(ledger_path)
      runs = entries.select { |entry| entry["type"] == "shadow_run" }.to_h { |entry| [ entry["case_id"], entry ] }
      raise ShadowEvaluationLedger::PendingHumanInput, "pending human input: every adjudicated case needs a shadow-run event" unless cases.all? { |item| runs.key?(item["id"]) }

      human = effective_human_verdicts(cases, entries)
      <<~MARKDOWN
        # RDR-067 Shadow Evaluation Aggregate Worksheet

        | Measure | Result | Ledger evidence |
        | --- | --- | --- |
        | False alarms | #{rate(human, runs, "accepted") { |verdict| verdict != "within_scope" }} | adjudication + shadow_run |
        | Missed material drift | #{rate(human, runs, "material_drift") { |verdict| verdict == "within_scope" }} | adjudication + shadow_run |
        | Escaped changes | not established | follow_up events required |
        | Review cost | #{runs.values.sum { |run| run["cost_cents"].to_i }} cents | shadow_run |
        | Human time | not established | active adjudication timestamps required |
        | Rework | not established | resolution and reviewed-head events required |
        | Delivery time | not established | delivery events and predeclared baseline required |

        ## Promotion decision

        Not established — required promotion-rule inputs are incomplete. No promotion decision is emitted.
      MARKDOWN
    end

    def effective_human_verdicts(cases, entries)
      adjudications = entries.select { |entry| entry["type"] == "adjudication" }
      cases.to_h do |item|
        decisions = adjudications.select { |entry| entry["case_id"] == item["id"] }
        [ item["id"], decisions.last.fetch("verdict") ]
      end
    end

    def rate(human, runs, expected)
      denominator = human.count { |_case_id, verdict| verdict == expected }
      return "not established" if denominator.zero?

      numerator = human.count { |case_id, verdict| verdict == expected && yield(runs.fetch(case_id).fetch("verdict")) }
      format("%.1f%% (%d / %d)", numerator * 100.0 / denominator, numerator, denominator)
    end
  end
end
