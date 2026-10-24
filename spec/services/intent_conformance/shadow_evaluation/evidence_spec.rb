# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-010
RSpec.describe IntentConformance::ShadowEvaluation::Evidence do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner, owner: "acme", repo: "widgets") }
  let(:client) { instance_double(GithubClient) }
  let(:dir) { Dir.mktmpdir }
  let(:manifest_path) { File.join(dir, "corpus.yml") }
  let(:corpus_case) do
    {
      "id" => "case-1", "repository" => "acme/widgets", "base_sha" => "a" * 40,
      "head_sha" => "b" * 40, "approved_design_revision" => "c" * 40,
      "design_document_paths" => [ "docs/rdrs/RDR-999.md" ],
      "selection_rationale" => "material drift expected", "notes" => "within_scope hint"
    }
  end
  let(:evaluation) do
    File.write(manifest_path, { "cases" => [ corpus_case ] }.to_yaml)
    create(:intent_conformance_shadow_evaluation, project:, solo_maintainer: owner, created_by: owner,
      manifest_path:, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  after { FileUtils.remove_entry(dir) }

  def call(kind:, path: nil)
    described_class.call(evaluation:, case_id: "case-1", kind:, path:, client:)
  end

  it "validates an exact diff before returning its revision-bound URL" do
    expect(client).to receive(:compare).with("acme/widgets", "a" * 40, "b" * 40).and_return({})

    result = call(kind: "diff")

    expect(result).to be_available
    expect(result.url).to eq("https://github.com/acme/widgets/compare/#{"a" * 40}...#{"b" * 40}")
  end

  it "validates a declared design artifact at its approved revision" do
    expect(client).to receive(:file_content)
      .with("acme/widgets", path: "docs/rdrs/RDR-999.md", ref: "c" * 40).and_return("# approved")

    result = call(kind: "design_document", path: "docs/rdrs/RDR-999.md")

    expect(result).to be_available
    expect(result.url).to eq("https://github.com/acme/widgets/blob/#{"c" * 40}/docs/rdrs/RDR-999.md")
  end

  it "does not navigate to undeclared or malicious artifact paths" do
    expect(call(kind: "design_document", path: "https://evil.example.com")).not_to be_available
    expect(call(kind: "design_document", path: "../secrets")).not_to be_available
  end

  it "rejects declared design artifacts with dot-segment paths" do
    corpus_case["design_document_paths"] = [ "docs/../LICENSE", "./docs/RDR-999.md", "docs/" ]

    [ "docs/../LICENSE", "./docs/RDR-999.md", "docs/" ].each do |path|
      result = call(kind: "design_document", path:)

      expect(result).not_to be_available
      expect(result.error).to eq("approved design artifact path is invalid")
    end
  end

  it "rejects non-string pinned revisions" do
    evaluation.update!(manifest_digest: "")
    corpus_case["base_sha"] = 1
    File.write(manifest_path, { "cases" => [ corpus_case ] }.to_yaml)

    result = call(kind: "diff")

    expect(result).not_to be_available
    expect(result.error).to eq("pinned diff has an invalid revision")
  end

  it "reports inaccessible pinned evidence as unavailable without a branch fallback" do
    allow(client).to receive(:compare).and_raise(GithubClient::NotFoundError, "not found")

    result = call(kind: "diff")

    expect(result).not_to be_available
    expect(result.url).to be_nil
    expect(result.error).to eq("pinned evidence is unavailable")
  end

  it "rejects cases outside the authorized project repository" do
    corpus_case["repository"] = "other/widgets"

    result = call(kind: "diff")

    expect(result).not_to be_available
    expect(result.error).to eq("case repository is outside this project")
  end

  it "rejects navigation when the manifest was edited after the evaluation started, even retaining the case id" do
    expect(evaluation.corpus.matches_recorded_digest?).to be(true)
    corpus_case["base_sha"] = "e" * 40
    corpus_case["head_sha"] = "f" * 40
    File.write(manifest_path, { "cases" => [ corpus_case ] }.to_yaml)

    result = call(kind: "diff")

    expect(result).not_to be_available
    expect(result.error).to eq("corpus manifest changed since the evaluation was created — start a new evaluation")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-010
  it "reports a removed corpus manifest as unavailable evidence" do
    evaluation.corpus.resolved_path
    FileUtils.remove_file(manifest_path)

    result = call(kind: "diff")

    expect(result).not_to be_available
    expect(result.url).to be_nil
    expect(result.error).to eq("pinned evidence is unavailable")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-010
  it "reports a removed corpus manifest as unavailable evidence before its path is resolved" do
    evaluation
    FileUtils.remove_file(manifest_path)

    result = call(kind: "diff")

    expect(result).not_to be_available
    expect(result.error).to eq("pinned evidence is unavailable")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-010
  it "reports an invalid corpus manifest as unavailable evidence" do
    evaluation.update!(manifest_digest: "")
    File.write(manifest_path, "cases: [")

    result = call(kind: "diff")

    expect(result).not_to be_available
    expect(result.error).to eq("pinned evidence is unavailable")
  end
end
