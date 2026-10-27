# frozen_string_literal: true

# Shared helper for shadow-evaluation service/request specs: writes a frozen
# corpus manifest with the identity fields the executor validates.
module ShadowEvaluationCorpusHelper
  CASE_TEMPLATE = {
    "stratum" => "accepted",
    "repository" => "acme/widgets",
    "base_sha" => "a" * 40,
    "head_sha" => "b" * 40,
    "approved_design_revision" => "c" * 40,
    "model" => "claude-sonnet-4-6",
    "prompt_version" => "review-run-v1",
    "design_document_paths" => [ "docs/rdrs/RDR-999-example.md" ]
  }.freeze

  def corpus_case(id, overrides = {})
    # Deep-duplicate the template so serialized fixtures never share the
    # inner objects (Psych would emit YAML anchors/aliases, which the
    # ledger's safe_load deliberately rejects).
    { "id" => id }.merge(CASE_TEMPLATE.deep_dup).merge(overrides)
  end

  # A corpus that passes the shared corpus-shape checks: ten cases in each
  # stratum with the full case identity (the CLI ledger's minimum corpus).
  def full_strata_corpus_cases
    prefixes = { "accepted" => "A", "intentionally_drifted" => "D", "uncertain" => "U" }
    IntentConformance::ShadowEvaluationLedger::CORPUS_STRATA.flat_map do |stratum|
      (1..10).map { |n| corpus_case(format("%s-%02d", prefixes.fetch(stratum), n), "stratum" => stratum) }
    end
  end

  def write_corpus_manifest(dir, cases, extra = {})
    path = File.join(dir, "corpus-manifest.yml")
    File.write(path, { "cases" => cases, "reviewer" => reviewer_identity }.merge(extra).to_yaml)
    path
  end

  def reviewer_identity
    {
      "model" => "claude-sonnet-4-6",
      "prompt_version" => IntentConformance::ReviewerLlm::PROMPT_VERSION,
      "prompt_sha256" => Digest::SHA256.hexdigest(IntentConformance::ReviewerLlm::PROMPT)
    }
  end

  def label_all!(evaluation, verdict: "within_scope")
    evaluation.corpus.case_ids.each do |case_id|
      IntentConformance::ShadowEvaluation::RecordLabel.call(
        evaluation: evaluation,
        actor: evaluation.solo_maintainer,
        case_id: case_id,
        outcome: verdict,
        cited_design_claim: "approved claim",
        reason: "matches the approved design"
      )
    end
  end

  def freeze!(evaluation)
    IntentConformance::ShadowEvaluation::FreezeLabels.call(evaluation: evaluation, actor: evaluation.solo_maintainer)
  end
end

RSpec.configure do |config|
  config.include ShadowEvaluationCorpusHelper, type: :service
  config.include ShadowEvaluationCorpusHelper, file_path: %r{spec/services/intent_conformance/shadow_evaluation}
  config.include ShadowEvaluationCorpusHelper, file_path: %r{spec/requests/projects/shadow_evaluations}
end
