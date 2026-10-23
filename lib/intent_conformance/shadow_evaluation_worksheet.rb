# frozen_string_literal: true

require_relative "shadow_evaluation_ledger"
require_relative "shadow_evaluation_policy"

module IntentConformance
  # Computes the RDR-067 aggregate measures required by the rollout record.
  # Blinded scoring always uses the ORIGINAL adjudicated reference labels;
  # post-result label revisions are reported as retained evidence and never
  # change a score.
  # @spec INTENT-CONFORMANCE-ROLLOUT-003 @spec INTENT-CONFORMANCE-ROLLOUT-008
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

        ## Provenance

        | Field | Value |
        | --- | --- |
        | Corpus manifest commit | #{manifest_commit} |
        | Corpus manifest digest | #{ShadowEvaluationLedger.manifest_digest(manifest_path)} |
        | Evaluation policy | #{policy_summary(entries)} |
        | Reviewer identities | #{runs.values.map { |run| "#{run["reviewer_model"]} (#{run["reviewer_run_id"]})" }.uniq.sort.join("; ")} |

        ## Measures

        | Measure | Result | Ledger evidence |
        | --- | --- | --- |
        | False alarms | #{rate(human, runs, "within_scope") { |verdict| verdict != "within_scope" }} | adjudication + shadow_run |
        | Missed material drift | #{rate(human, runs, "material_drift") { |verdict| verdict == "within_scope" }} | adjudication + shadow_run |
        | Uncertainty handling | #{uncertainty_handling(human, runs)} | adjudication + shadow_run |
        | Confusion counts | #{confusion_counts(human, runs)} | adjudication + shadow_run |
        | Escaped changes | not established | follow_up events required |
        | Review cost | #{runs.values.sum { |run| run["cost_cents"].to_i }} cents | shadow_run |
        | Human time | not established | active adjudication timestamps required |
        | Rework | not established | resolution and reviewed-head events required |
        | Delivery time | not established | delivery events and predeclared baseline required |

        #{revisions_section(entries)}## Promotion decision

        Not established — required promotion-rule inputs are incomplete. No promotion decision is emitted.
      MARKDOWN
    end

    # Reference verdict per case from the ORIGINAL adjudications. The legacy
    # team verdict "accepted" and the solo label "within_scope" are the same
    # reference class, so both normalize to "within_scope" for comparison
    # with reviewer verdicts.
    def effective_human_verdicts(cases, entries)
      adjudications = entries.select { |entry| entry["type"] == "adjudication" }
      cases.to_h do |item|
        decisions = adjudications.select { |entry| entry["case_id"] == item["id"] }
        [ item["id"], normalize_verdict(majority_verdict(decisions)) ]
      end
    end

    # @spec INTENT-CONFORMANCE-ROLLOUT-003
    # Ledger validation guarantees either the two primary verdicts agree, or a
    # third tie-break verdict matches one of them — so the majority verdict
    # (by count) is always the human-adjudicated outcome, never a lone
    # tie-break verdict that corroborates neither primary adjudicator.
    def majority_verdict(decisions)
      tally = decisions.map { |entry| entry.fetch("verdict") }.tally
      tally.max_by { |_verdict, count| count }.first
    end

    def normalize_verdict(verdict)
      verdict == "accepted" ? "within_scope" : verdict
    end

    def rate(human, runs, expected)
      denominator = human.count { |_case_id, verdict| verdict == expected }
      return "not established" if denominator.zero?

      numerator = human.count { |case_id, verdict| verdict == expected && yield(runs.fetch(case_id).fetch("verdict")) }
      format("%.1f%% (%d / %d)", numerator * 100.0 / denominator, numerator, denominator)
    end

    # Reviewer uncertainty is never silently treated as agreement: it counts
    # as a false alarm on conforming references and as non-detection on
    # drifted ones, and it is surfaced verbatim on uncertain references.
    def uncertainty_handling(human, runs)
      uncertain_references = human.count { |_case_id, verdict| verdict == "uncertain" }
      reviewer_uncertain = human.count { |case_id, _verdict| runs.fetch(case_id).fetch("verdict") == "uncertain" }
      "#{uncertain_references} uncertain references, #{reviewer_uncertain} reviewer uncertain verdicts (uncertain never counts as agreement)"
    end

    def confusion_counts(human, runs)
      ShadowEvaluationLedger::REVIEWER_VERDICTS.map do |reference|
        row = ShadowEvaluationLedger::REVIEWER_VERDICTS.map do |reviewer|
          human.count { |case_id, verdict| verdict == reference && runs.fetch(case_id).fetch("verdict") == reviewer }
        end
        "#{reference}→[#{row.join(', ')}]"
      end.join(" · ") + " (reference→[within_scope, material_drift, uncertain])"
    end

    def policy_summary(entries)
      declaration = ShadowEvaluationPolicy.declaration_for(entries)
      return "team (two independent operators; default)" if declaration.nil?

      "solo maintainer #{declaration.maintainer} (explicitly selected; no independence — weaker evidence than the team policy)"
    end

    # Post-result revisions are appended, reasoned evidence; the original
    # blinded labels above are untouched.
    def revisions_section(entries)
      revisions = entries.select { |entry| entry["type"] == "label_revision" }
      return "" if revisions.empty?

      lines = revisions.map { |revision| "| #{revision["case_id"]} | #{revision["original_verdict"]} | #{revision["revised_verdict"]} | #{revision["reason"]} |" }
      <<~MARKDOWN
        ## Post-result label revisions (never rescored)

        | Case | Original label | Revised label | Reason |
        | --- | --- | --- | --- |
        #{lines.join("\n")}

      MARKDOWN
    end
  end
end
