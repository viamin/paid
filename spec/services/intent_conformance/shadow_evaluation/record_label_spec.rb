# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-005
RSpec.describe IntentConformance::ShadowEvaluation::RecordLabel do
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

  def call(actor: owner, case_id: "A-01", outcome: "within_scope", claim: "approved claim", reason: "matches design")
    described_class.call(evaluation: evaluation, actor: actor, case_id: case_id, outcome: outcome,
      cited_design_claim: claim, reason: reason)
  end

  it "records a complete blinded label for the declared maintainer" do
    result = call(case_id: "A-01", outcome: "material_drift", claim: "RDR-999 §2 behavior", reason: "widens scope")

    expect(result).to be_success
    expect(result.label).to have_attributes(case_id: "A-01", state: "labeled", outcome: "material_drift", recorded_by: owner)
    expect(result.label.recorded_at).to be_present
  end

  it "saves durably and resumes by updating in place" do
    call(case_id: "A-01", outcome: "uncertain")
    second = call(case_id: "A-01", outcome: "within_scope")

    expect(second).to be_success
    expect(evaluation.labels.where(case_id: "A-01").count).to eq(1)
    expect(evaluation.labels.find_by(case_id: "A-01").outcome).to eq("within_scope")
  end

  it "skips a case without ever counting it as completed" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "A-01", outcome: nil)

    expect(result).to be_success
    expect(result.label).to have_attributes(state: "skipped", outcome: nil)
    expect(evaluation.progress[:labeled]).to eq(0)
    expect(evaluation.progress[:skipped]).to eq(1)
  end

  it "rejects an operator other than the declared maintainer" do
    expect(call(actor: other_member)).not_to be_success
  end

  it "rejects an unknown outcome" do
    expect(call(outcome: "accepted")).not_to be_success
  end

  it "rejects a label without a cited claim or reason" do
    expect(call(claim: " ")).not_to be_success
    expect(call(reason: nil)).not_to be_success
  end

  it "rejects a case outside the frozen corpus" do
    expect(call(case_id: "TYPO")).not_to be_success
  end

  it "rejects labeling after the reference set is frozen" do
    label_all!(evaluation)
    freeze!(evaluation)

    expect(call(case_id: "A-01")).not_to be_success
  end

  # A double-submit of the same case races find_or_initialize_by; the loser
  # must retry as an in-place update of the surviving row rather than surface
  # the unique (shadow_evaluation_id, case_id) index as a 500 (#4598 review).
  it "updates the surviving row in place when a double submit races the label index" do
    call(case_id: "A-01", outcome: "within_scope")
    racing_duplicate = evaluation.labels.new(case_id: "A-01")
    allow(evaluation.labels).to receive(:find_or_initialize_by).with(case_id: "A-01").and_return(racing_duplicate)

    result = call(case_id: "A-01", outcome: "material_drift", claim: "claim 2", reason: "reason 2")

    expect(result).to be_success
    expect(result.label).to have_attributes(state: "labeled", outcome: "material_drift")
    expect(evaluation.labels.where(case_id: "A-01")).to contain_exactly(result.label)
  end
end
