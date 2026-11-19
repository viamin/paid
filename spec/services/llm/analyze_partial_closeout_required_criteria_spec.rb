# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-017
RSpec.describe Llm::AnalyzePartialCloseout do
  let(:project) { create(:project) }
  let(:owner) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let(:agent_run) { create(:agent_run, :completed, project:, issue:, goal: "analyze_issue") }
  let(:criterion) { "Cover failed git stash push and pre-existing stash entries" }
  let(:service) { described_class.new(agent_run:) }
  let(:with_mapping) { true }

  before do
    if with_mapping
      enrollment = StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
      StagedCloseoutMapping.create!(account: project.account, project:, issue:,
        staged_closeout_enrollment: enrollment, reviewed_by: owner, reviewed_at: Time.current,
        criterion_key: criterion, criterion_digest: StagedCloseoutMapping.digest_for(issue:, criterion_key: criterion),
        stage: "merged_revision", phase: "release_deployment", target_shape: "source_pr_merged_revision",
        execution_path: "technical_prerequisite", target_key: "unit-recipe", target_version: "1",
        target_digest: "unit-digest", freshness_seconds: 60, revision: 1)
    end
  end

  def response(keys)
    { "gaps" => [], "criteria" => keys.map { |key| { "criterion" => key, "state" => "unknown" } } }
  end

  it "accepts the exact required identity without deciding satisfaction" do
    expect(service.send(:valid_assessment?, response([ criterion ]))).to be(true)
  end

  it "rejects a paraphrased required criterion" do
    expect(service.send(:valid_assessment?, response([ criterion.sub("Cover failed", "Cover a failed") ]))).to be(false)
  end

  it "rejects an omitted required criterion" do
    expect(service.send(:valid_assessment?, response([]))).to be(false)
  end

  it "offers criterion identity failures to the normal fallback response validator" do
    result = Struct.new(:output).new(response([ "Paraphrased criterion" ]).to_json)

    expect(service.send(:response_contract_valid?, result)).to be(false)
    expect(service.send(:invalid_fields, response([]))).to include(
      include(path: "criteria.required_identities", actual: "array")
    )
  end

  it "rejects duplicate required identities" do
    expect(service.send(:valid_assessment?, response([ criterion, criterion ]))).to be(false)
  end

  it "allows discovery of additional unmapped criteria" do
    expect(service.send(:valid_assessment?, response([ criterion, "Additional criterion" ]))).to be(true)
  end

  it "does not carry obsolete mapping identities into changed approved intent" do
    create(:agent_run, :completed, project:, issue:, goal: "analyze_issue",
      reconciliation: { "assessment" => { "criteria" => [ { "criterion" => criterion, "state" => "unknown" } ] } })
    issue.update!(body: "Different approved intent")

    expect(service.send(:valid_assessment?, response([ "Changed criterion" ]))).to be(true)
  end

  it "supplies the exact reviewed identity as data in the prompt" do
    allow(service).to receive(:audit_evidence).and_return(instance_double(PartialCloseouts::AuditEvidence, call: "{}"))

    expect(service.send(:prompt)).to include("do not paraphrase", [ criterion ].to_json)
  end

  context "without reviewed mappings" do
    let(:with_mapping) { false }

    it "preserves legacy criterion discovery" do
      expect(service.send(:valid_assessment?, response([ "Newly identified criterion" ]))).to be(true)
    end
  end
end
