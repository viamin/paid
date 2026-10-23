# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-009
RSpec.describe IntentConformance::ShadowEvaluation::Start do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:manifest_path) { File.join(dir, "manifest.yml") }

  before { File.write(manifest_path, manifest_yaml) }

  after { FileUtils.remove_entry(dir) }

  def manifest_yaml(cases = [ { "id" => "A-01", "stratum" => "accepted", "repository" => "acme/widgets", "base_sha" => "a", "head_sha" => "b", "approved_design_revision" => "r", "model" => "m", "prompt_version" => "v" } ])
    { "cases" => cases }.to_yaml
  end

  def call(policy: "solo")
    described_class.call(project: project, actor: owner, purpose: "rdr-067-measured-rollout", policy: policy, manifest_path: manifest_path)
  end

  it "starts a solo evaluation bound to the manifest digest" do
    result = call

    expect(result).to be_success
    expect(result.evaluation).to have_attributes(project: project, policy: "solo", status: "labeling", solo_maintainer: owner)
    expect(result.evaluation.manifest_digest).to eq(Digest::SHA256.file(manifest_path).hexdigest)
  end

  it "resumes the existing evaluation for the same evidence generation instead of duplicating" do
    first = call
    second = call

    expect(second).to be_success
    expect(second.resumed).to be(true)
    expect(second.evaluation.id).to eq(first.evaluation.id)
    expect(IntentConformanceShadowEvaluation.count).to eq(1)
  end

  it "starts a new evidence generation when the corpus digest changes, keeping the old record" do
    first = call
    File.write(manifest_path, manifest_yaml([ { "id" => "B-01", "stratum" => "accepted", "repository" => "acme/widgets", "base_sha" => "a", "head_sha" => "b", "approved_design_revision" => "r", "model" => "m", "prompt_version" => "v" } ]))
    second = call

    expect(second.evaluation.id).not_to eq(first.evaluation.id)
    expect(first.evaluation.reload.manifest_digest).not_to eq(second.evaluation.manifest_digest)
  end

  it "requires the solo policy to be explicitly selected" do
    expect(call(policy: "team")).not_to be_success
  end

  it "fails clearly when the manifest is missing" do
    result = described_class.call(project: project, actor: owner, purpose: "p", policy: "solo", manifest_path: File.join(dir, "nope.yml"))

    expect(result).not_to be_success
    expect(result.error).to include("was not found")
  end
end
