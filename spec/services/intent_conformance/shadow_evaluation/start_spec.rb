# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-009
RSpec.describe IntentConformance::ShadowEvaluation::Start do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:cases) { full_strata_corpus_cases }
  let(:manifest_path) { "manifest.yml" }
  let(:commit_without_manifest) { git_write!(dir, "other.yml", "other", "add other file") }
  let(:manifest_commit) { commit_without_manifest && git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "add corpus manifest") }

  before do
    init_git_repo(dir)
    allow(Rails).to receive(:root).and_return(Pathname.new(dir))
  end

  after { FileUtils.remove_entry(dir) }

  def write_manifest(new_cases)
    git_write!(dir, manifest_path, { "cases" => new_cases }.to_yaml, "update corpus manifest")
  end

  def call(policy: "solo", manifest_commit: self.manifest_commit)
    described_class.call(project: project, actor: owner, purpose: "rdr-067-measured-rollout", policy: policy, manifest_path: manifest_path,
      manifest_commit: manifest_commit)
  end

  it "starts a solo evaluation bound to the manifest digest" do
    result = call

    expect(result).to be_success
    expect(result.evaluation).to have_attributes(project: project, policy: "solo", status: "labeling", solo_maintainer: owner)
    expect(result.evaluation.manifest_digest).to eq(Digest::SHA256.file(File.join(dir, manifest_path)).hexdigest)
    expect(result.evaluation.manifest_commit).to eq(manifest_commit)
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
    updated_commit = write_manifest(cases.map { |corpus_case| corpus_case == cases.first ? corpus_case.merge("head_sha" => "z" * 40) : corpus_case })
    second = call(manifest_commit: updated_commit)

    expect(second.evaluation.id).not_to eq(first.evaluation.id)
    expect(first.evaluation.reload.manifest_digest).not_to eq(second.evaluation.manifest_digest)
  end

  it "requires the solo policy to be explicitly selected" do
    expect(call(policy: "team")).not_to be_success
  end

  it "fails clearly when the manifest is missing" do
    result = described_class.call(project: project, actor: owner, purpose: "p", policy: "solo", manifest_path: "nope.yml",
      manifest_commit: manifest_commit)

    expect(result).not_to be_success
    expect(result.error).to include("was not found")
  end

  it "resumes the surviving evaluation when a concurrent start wins the unique-index race" do
    winner = nil
    allow(IntentConformanceShadowEvaluation).to receive(:create!).and_wrap_original do |original, **attributes|
      winner = original.call(**attributes)
      raise ActiveRecord::RecordNotUnique, "simulated concurrent start inserted the row first"
    end

    result = call

    expect(result).to be_success
    expect(result.resumed).to be(true)
    expect(result.evaluation.id).to eq(winner.id)
    expect(IntentConformanceShadowEvaluation.count).to eq(1)
  end

  # The form accepts an operator-supplied manifest path, so Start applies the
  # same corpus-shape checks as the CLI ledger before an evaluation exists
  # (#4598 review).
  it "refuses a corpus with fewer than ten cases in a stratum" do
    updated_commit = write_manifest(full_strata_corpus_cases.drop(1))

    result = call(manifest_commit: updated_commit)

    expect(result).not_to be_success
    expect(result.error).to include("at least ten cases in each stratum")
    expect(IntentConformanceShadowEvaluation.count).to eq(0)
  end

  it "refuses a case without a valid stratum" do
    updated_commit = write_manifest(full_strata_corpus_cases + [ corpus_case("X-01", "stratum" => nil) ])

    result = call(manifest_commit: updated_commit)

    expect(result).not_to be_success
    expect(result.error).to include("X-01").and include("lacks a valid stratum")
    expect(IntentConformanceShadowEvaluation.count).to eq(0)
  end

  it "refuses a case missing required repository, revision, or model/prompt identity" do
    updated_commit = write_manifest(full_strata_corpus_cases + [ corpus_case("X-01", "model" => "") ])

    result = call(manifest_commit: updated_commit)

    expect(result).not_to be_success
    expect(result.error).to include("X-01").and include("repository, revision, or model/prompt identity")
    expect(IntentConformanceShadowEvaluation.count).to eq(0)
  end

  it "refuses duplicate or missing case ids" do
    duplicate_commit = write_manifest(full_strata_corpus_cases + [ corpus_case("A-01") ])

    expect(call(manifest_commit: duplicate_commit).error).to include("case ids must be unique")

    missing_id_commit = write_manifest(full_strata_corpus_cases + [ corpus_case("") ])
    expect(call(manifest_commit: missing_id_commit).error).to include("every case needs an id")

    empty_commit = write_manifest([])
    expect(call(manifest_commit: empty_commit).error).to include("cases list must not be empty")
    expect(IntentConformanceShadowEvaluation.count).to eq(0)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-008
  it "rejects a local manifest that does not match its declared commit" do
    committed_manifest = manifest_commit
    File.write(File.join(dir, manifest_path), { "cases" => full_strata_corpus_cases.drop(1) }.to_yaml)

    result = call(manifest_commit: committed_manifest)

    expect(result).not_to be_success
    expect(result.error).to include("does not match")
    expect(IntentConformanceShadowEvaluation.count).to eq(0)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-008
  it "rejects a commit that does not contain the manifest" do
    manifest_commit
    result = call(manifest_commit: commit_without_manifest)

    expect(result).not_to be_success
    expect(result.error).to include("absent from commit")
    expect(IntentConformanceShadowEvaluation.count).to eq(0)
  end
end
