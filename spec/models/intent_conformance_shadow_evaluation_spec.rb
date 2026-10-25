# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-006
RSpec.describe IntentConformanceShadowEvaluation do
  describe "validations" do
    it "requires an explicit policy, status, purpose, and manifest path" do
      evaluation = described_class.new(project: nil, policy: nil, status: nil, purpose: nil, manifest_path: nil)

      expect(evaluation).not_to be_valid
      expect(evaluation.errors.full_messages.join(", ")).to include("Project").and include("Policy").and include("Status").and include("Manifest path")
    end

    it "requires a solo maintainer for the solo policy" do
      evaluation = build(:intent_conformance_shadow_evaluation, solo_maintainer: nil)

      expect(evaluation).not_to be_valid
      expect(evaluation.errors[:solo_maintainer]).to be_present
    end

    it "rejects an unknown status" do
      evaluation = build(:intent_conformance_shadow_evaluation, status: "done")

      expect(evaluation).not_to be_valid
    end
  end

  describe "lifecycle helpers" do
    it "treats answers as visible only after the explicit freeze" do
      evaluation = create(:intent_conformance_shadow_evaluation)

      expect(evaluation).to be_labeling
      expect(evaluation).to be_blinded

      evaluation.update!(status: "frozen", labels_frozen_at: Time.current)

      expect(evaluation).to be_frozen
      expect(evaluation).not_to be_blinded
      expect(evaluation).to be_answers_visible
    end

    it "counts labeled and skipped cases separately" do
      dir = Dir.mktmpdir
      manifest_path = File.join(dir, "corpus-manifest.yml")
      File.write(manifest_path, { "cases" => [ { "id" => "A-01" }, { "id" => "A-02" } ] }.to_yaml)
      evaluation = create(:intent_conformance_shadow_evaluation, manifest_path: manifest_path,
        manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
      create(:intent_conformance_shadow_evaluation_label, shadow_evaluation: evaluation, case_id: "A-01", state: "labeled", recorded_by: evaluation.solo_maintainer)
      create(:intent_conformance_shadow_evaluation_label, shadow_evaluation: evaluation, case_id: "A-02", state: "skipped", outcome: nil, cited_design_claim: nil, reason: nil, recorded_by: evaluation.solo_maintainer)

      expect(evaluation.progress).to eq(total: 2, labeled: 1, skipped: 1)
      expect(evaluation.labeled_case_ids).to include("A-01")
    ensure
      FileUtils.remove_entry(dir)
    end

    # @spec INTENT-CONFORMANCE-ROLLOUT-011 — durable execution lifecycle
    # states with per-case progress and cost.
    it "exposes the asynchronous execution states and pending guard" do
      evaluation = build(:intent_conformance_shadow_evaluation)

      expect(described_class::STATUSES).to include("queued", "executing", "partial", "cancelled")
      expect(evaluation).not_to be_execution_pending
      %w[queued executing partial failed cancelled completed].each do |status|
        expect(build(:intent_conformance_shadow_evaluation, status: status)).to be_frozen
      end
      expect(build(:intent_conformance_shadow_evaluation, status: "queued")).to be_execution_pending
      expect(build(:intent_conformance_shadow_evaluation, status: "executing")).to be_execution_pending
    end

    it "reports execution progress with evaluated counts and spend" do
      dir = Dir.mktmpdir
      manifest_path = File.join(dir, "corpus-manifest.yml")
      File.write(manifest_path, { "cases" => [ { "id" => "A-01" }, { "id" => "A-02" } ] }.to_yaml)
      evaluation = create(:intent_conformance_shadow_evaluation, manifest_path: manifest_path,
        manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
      create(:intent_conformance_shadow_evaluation_run, shadow_evaluation: evaluation, case_id: "A-01",
        verdict: "within_scope", cost_cents: 42, recorded_at: Time.current)
      create(:intent_conformance_shadow_evaluation_run, shadow_evaluation: evaluation, case_id: "A-02",
        verdict: "not_evaluated", failure_reason: "unsuccessful_response", cost_cents: 7, recorded_at: Time.current)

      expect(evaluation.execution_progress).to eq(total: 2, evaluated: 1, not_evaluated: 1, cost_cents: 49)
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe IntentConformanceShadowEvaluationRun do
    it "rejects an unknown verdict" do
      run = build(:intent_conformance_shadow_evaluation_run, verdict: "approved")

      expect(run).not_to be_valid
    end

    it "classifies not_evaluated separately from evaluated verdicts" do
      expect(build(:intent_conformance_shadow_evaluation_run, :not_evaluated)).to be_not_evaluated
      expect(build(:intent_conformance_shadow_evaluation_run)).to be_evaluated
    end
  end
end
