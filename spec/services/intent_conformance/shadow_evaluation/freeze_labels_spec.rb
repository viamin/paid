# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-006
RSpec.describe IntentConformance::ShadowEvaluation::FreezeLabels do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:other_member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:cases) { [ corpus_case("A-01"), corpus_case("A-02") ] }
  let(:manifest_path) { write_corpus_manifest(dir, cases) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  after { FileUtils.remove_entry(dir) }

  def call(actor: owner)
    described_class.call(evaluation: evaluation, actor: actor)
  end

  it "freezes the reference set once every case carries a complete label" do
    label_all!(evaluation)

    expect(call).to be_success
    expect(evaluation.reload).to be_frozen
    expect(evaluation.labels_frozen_at).to be_present
  end

  it "refuses to freeze while a case is unlabeled" do
    IntentConformance::ShadowEvaluation::RecordLabel.call(evaluation: evaluation, actor: owner, case_id: "A-01",
      outcome: "within_scope", cited_design_claim: "claim", reason: "reason")

    result = call

    expect(result).not_to be_success
    expect(result.error).to include("A-02").and include("unlabeled or skipped")
    expect(evaluation.reload).to be_labeling
    expect(evaluation.labels_frozen_at).to be_nil
  end

  it "refuses to freeze while a case is skipped, never counting it as completed" do
    label_all!(evaluation)
    IntentConformance::ShadowEvaluation::RecordLabel.call(evaluation: evaluation, actor: owner, case_id: "A-01", outcome: nil)

    result = call

    expect(result).not_to be_success
    expect(result.error).to include("A-01").and include("unlabeled or skipped")
    expect(evaluation.reload).to be_labeling
  end

  it "rejects an operator other than the declared maintainer" do
    label_all!(evaluation)

    expect(call(actor: other_member)).not_to be_success
  end

  it "refuses a second freeze" do
    label_all!(evaluation)
    freeze!(evaluation)

    expect(call).not_to be_success
  end

  it "applies the same shared validation as the CLI ledger" do
    label_all!(evaluation)
    allow(IntentConformance::ShadowEvaluationPolicy).to receive(:validate_reference_labels!).and_call_original

    call

    expect(IntentConformance::ShadowEvaluationPolicy).to have_received(:validate_reference_labels!)
  end
end
