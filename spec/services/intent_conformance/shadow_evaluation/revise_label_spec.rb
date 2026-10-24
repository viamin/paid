# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-008
RSpec.describe IntentConformance::ShadowEvaluation::ReviseLabel do
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

  def call(actor: owner, case_id: "A-01", revised_outcome: "material_drift", reason: "reviewer cited a constraint I missed")
    described_class.call(evaluation: evaluation, actor: actor, case_id: case_id, revised_outcome: revised_outcome, reason: reason)
  end

  before do
    label_all!(evaluation, verdict: "within_scope")
    freeze!(evaluation)
  end

  it "appends a reasoned revision after the case's reviewer run, preserving the original label" do
    evaluation.runs.create!(case_id: "A-01", verdict: "material_drift", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 0, recorded_at: Time.current)

    result = call

    expect(result).to be_success
    label = evaluation.labels.find_by(case_id: "A-01")
    expect(label.outcome).to eq("within_scope")
    expect(label).to have_attributes(revised_outcome: "material_drift", revised_by: owner)
    expect(label.scoring_outcome).to eq("within_scope")
  end

  it "rejects a revision recorded before the case's reviewer output exists" do
    result = call

    expect(result).not_to be_success
    expect(result.error).to include("after the case's reviewer output")
  end

  it "rejects a second revision of the same label" do
    evaluation.runs.create!(case_id: "A-01", verdict: "material_drift", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 0, recorded_at: Time.current)
    call(case_id: "A-01")

    second = call(case_id: "A-01")

    expect(second).not_to be_success
  end

  it "rejects an operator other than the declared maintainer" do
    evaluation.runs.create!(case_id: "A-01", verdict: "material_drift", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 0, recorded_at: Time.current)

    expect(call(actor: other_member)).not_to be_success
  end

  it "rejects a revision without a reason or with an invalid outcome" do
    evaluation.runs.create!(case_id: "A-01", verdict: "material_drift", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 0, recorded_at: Time.current)

    expect(call(reason: " ")).not_to be_success
    expect(call(revised_outcome: "accepted")).not_to be_success
  end
end
