# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::CriterionInputReceipts do
  # @spec LIVE-PREVIEW-013
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, project: project, issue: issue) }
  let(:repo_path) { Dir.mktmpdir("criterion-input-receipts-spec") }
  let(:head_commit) { "a" * 40 }
  let(:spec_path) { "spec/services/settings_spec.rb" }
  let(:spec_content) { "it \"saves settings\" do\n  expect(Settings.save).to be(true)\nend\n" }
  let(:spec_digest) { "sha256:#{Digest::SHA256.hexdigest(spec_content)}" }
  let(:retained_key) { "screenshots/acme/widgets/verification/#{agent_run.id}/#{head_commit}/app.log" }

  def receipt_for(inputs)
    criteria = [ { "id" => "AC-1", "verification" => { "inputs" => inputs } } ]
    described_class.call(
      agent_run: agent_run,
      repo_path: repo_path,
      criteria: criteria,
      tested_commit: head_commit,
      retained_storage_keys: [ retained_key ]
    ).fetch("AC-1")
  end

  before do
    FileUtils.mkdir_p(File.dirname(File.join(repo_path, spec_path)))
    File.binwrite(File.join(repo_path, spec_path), spec_content)
  end

  after do
    FileUtils.rm_rf(repo_path)
  end

  context "with genuine repository input references" do
    it "labels a path pinned to the reviewed commit with a matching digest verified" do
      receipt = receipt_for([
        { "type" => "repo_path", "path" => spec_path, "commit" => head_commit, "digest" => spec_digest }
      ])

      expect(receipt["state"]).to eq("verified")
      expect(receipt["references"]).to contain_exactly(
        hash_including("type" => "repo_path", "locator" => spec_path, "state" => "verified")
      )
      expect(receipt["counts"]).to include("total" => 1, "verified" => 1, "contradicted" => 0)
    end

    it "labels a matching excerpt verified without a digest" do
      receipt = receipt_for([
        { "type" => "repo_path", "path" => spec_path, "commit" => head_commit, "excerpt" => "expect(Settings.save)" }
      ])

      expect(receipt["references"].first["state"]).to eq("verified")
    end

    it "labels a canonical spec revision verified when revision and digest match" do
      receipt = receipt_for([
        { "type" => "spec_revision", "path" => spec_path, "revision" => head_commit, "digest" => spec_digest }
      ])

      expect(receipt["references"].first["state"]).to eq("verified")
    end
  end

  context "with fabricated input references" do
    it "labels a nonexistent path unavailable" do
      receipt = receipt_for([
        { "type" => "repo_path", "path" => "spec/invented_spec.rb", "commit" => head_commit, "digest" => spec_digest }
      ])

      expect(receipt["references"].first).to include("state" => "unavailable", "reason" => "path_not_found")
      expect(receipt["state"]).to eq("unavailable")
    end

    it "labels changed content contradicted via digest mismatch" do
      receipt = receipt_for([
        { "type" => "repo_path", "path" => spec_path, "commit" => head_commit,
          "digest" => "sha256:#{Digest::SHA256.hexdigest("entirely different content")}" }
      ])

      expect(receipt["references"].first).to include("state" => "contradicted", "reason" => "digest_mismatch")
      expect(receipt["state"]).to eq("contradicted")
    end

    it "labels an excerpt absent from the cited file contradicted" do
      receipt = receipt_for([
        { "type" => "repo_path", "path" => spec_path, "commit" => head_commit, "excerpt" => "this assertion does not exist" }
      ])

      expect(receipt["references"].first).to include("state" => "contradicted", "reason" => "excerpt_not_found")
    end

    it "labels a repository-escaping path unavailable" do
      receipt = receipt_for([
        { "type" => "repo_path", "path" => "../outside.rb", "commit" => head_commit, "digest" => spec_digest }
      ])

      expect(receipt["references"].first).to include("state" => "unavailable", "reason" => "outside_repo")
    end
  end

  context "with stale input references" do
    it "labels a reference pinned to a different revision stale" do
      receipt = receipt_for([
        { "type" => "repo_path", "path" => spec_path, "commit" => "b" * 40, "digest" => spec_digest }
      ])

      expect(receipt["references"].first).to include("state" => "stale", "reason" => "revision_mismatch")
      expect(receipt["state"]).to eq("stale")
    end

    it "labels an unpinned reference unavailable rather than guessing the revision" do
      receipt = receipt_for([ { "type" => "repo_path", "path" => spec_path, "digest" => spec_digest } ])

      expect(receipt["references"].first).to include("state" => "unavailable", "reason" => "commit_not_pinned")
    end

    it "labels a reference without digest or excerpt unavailable" do
      receipt = receipt_for([ { "type" => "repo_path", "path" => spec_path, "commit" => head_commit } ])

      expect(receipt["references"].first).to include("state" => "unavailable", "reason" => "content_binding_missing")
    end
  end

  context "with test-run input references" do
    it "labels a skipped test claim contradicted so it cannot support a receipt" do
      receipt = receipt_for([
        { "type" => "test_run", "command" => "bin/rspec spec/services/settings_spec.rb", "result" => "skipped" }
      ])

      expect(receipt["references"].first).to include("state" => "contradicted", "reason" => "reported_result_not_passing")
    end

    it "labels a failed test claim contradicted" do
      receipt = receipt_for([
        { "type" => "test_run", "command" => "bin/rspec spec/services/settings_spec.rb", "result" => "failed" }
      ])

      expect(receipt["references"].first["state"]).to eq("contradicted")
    end

    it "labels a passed claim unavailable when Paid holds no recorder-owned execution" do
      receipt = receipt_for([
        { "type" => "test_run", "command" => "bin/rspec spec/services/settings_spec.rb", "result" => "passed" }
      ])

      expect(receipt["references"].first).to include(
        "state" => "unavailable", "reason" => "no_recorder_owned_execution"
      )
    end

    it "labels a commandless test reference malformed" do
      receipt = receipt_for([ { "type" => "test_run", "result" => "passed" } ])

      expect(receipt["references"].first).to include("state" => "unavailable", "reason" => "malformed_reference")
    end
  end

  context "with artifact input references" do
    it "labels a recorder-retained artifact key verified" do
      receipt = receipt_for([ { "type" => "artifact", "storage_key" => retained_key } ])

      expect(receipt["references"].first).to include("state" => "verified")
    end

    it "labels a key in the run namespace that was not retained unavailable" do
      receipt = receipt_for([
        { "type" => "artifact", "storage_key" => "screenshots/acme/widgets/verification/#{agent_run.id}/#{head_commit}/other.log" }
      ])

      expect(receipt["references"].first).to include("state" => "unavailable", "reason" => "artifact_not_retained")
    end

    it "labels a key outside recorder-owned provenance unavailable" do
      receipt = receipt_for([ { "type" => "artifact", "storage_key" => "screenshots/other-org/widgets/report.png" } ])

      expect(receipt["references"].first).to include("state" => "unavailable", "reason" => "provenance_not_recorder_owned")
    end

    it "labels an in-repo artifact path verified when the file exists" do
      receipt = receipt_for([ { "type" => "artifact", "path" => spec_path } ])

      expect(receipt["references"].first).to include("state" => "verified")
    end
  end

  context "with human or external input references" do
    it "keeps the reference visible but unavailable to mechanical verification" do
      receipt = receipt_for([
        { "type" => "external", "url" => "https://example.test/review", "description" => "Manual sign-off" }
      ])

      expect(receipt["references"].first).to include(
        "state" => "unavailable", "reason" => "external_reference_requires_human_review"
      )
      expect(receipt["state"]).to eq("unavailable")
    end
  end

  it "records explicit missing evidence when a criterion cites no inputs" do
    receipt = receipt_for([])

    expect(receipt).to include("state" => "unavailable", "reason" => "no_input_references_cited")
    expect(receipt["references"]).to eq([])
  end

  it "aggregates mixed references with the strongest failure winning" do
    receipt = receipt_for([
      { "type" => "repo_path", "path" => spec_path, "commit" => head_commit, "digest" => spec_digest },
      { "type" => "repo_path", "path" => spec_path, "commit" => head_commit,
        "digest" => "sha256:#{Digest::SHA256.hexdigest("entirely different content")}" },
      { "type" => "repo_path", "path" => spec_path, "commit" => "b" * 40, "digest" => spec_digest },
      { "type" => "repo_path", "path" => "spec/missing.rb", "commit" => head_commit, "digest" => spec_digest }
    ])

    expect(receipt["state"]).to eq("contradicted")
    expect(receipt["counts"]).to eq(
      "total" => 4, "verified" => 1, "contradicted" => 1, "stale" => 1, "unavailable" => 1
    )
  end

  it "withholds a verified criterion receipt when any cited input is unverifiable" do
    receipt = receipt_for([
      { "type" => "repo_path", "path" => spec_path, "commit" => head_commit, "digest" => spec_digest },
      { "type" => "repo_path", "path" => "spec/missing.rb", "commit" => head_commit, "digest" => spec_digest }
    ])

    expect(receipt).to include("state" => "unavailable", "reason" => "no_verifiable_input_references")
  end

  it "bounds the number of references assessed per criterion" do
    inputs = Array.new(30) { { "type" => "external", "description" => "ref" } }
    receipt = receipt_for(inputs)

    expect(receipt["references"].length).to eq(described_class::MAX_INPUTS)
    expect(receipt["counts"].fetch("total")).to eq(described_class::MAX_INPUTS)
  end

  it "redacts secrets from persisted reference locators" do
    receipt = receipt_for([ { "type" => "test_run", "command" => "run token=super-secret-value", "result" => "passed" } ])

    locator = receipt["references"].first.fetch("locator")
    expect(locator).to include("[REDACTED")
    expect(locator).not_to include("super-secret-value")
  end

  it "skips criteria without an id and unknown input types" do
    receipts = described_class.call(
      agent_run: agent_run,
      repo_path: repo_path,
      criteria: [
        { "verification" => { "inputs" => [ { "type" => "repo_path", "path" => spec_path, "commit" => head_commit, "digest" => spec_digest } ] } },
        { "id" => "AC-9", "verification" => { "inputs" => [ { "type" => "mystery", "path" => spec_path } ] } }
      ],
      tested_commit: head_commit,
      retained_storage_keys: []
    )

    expect(receipts.keys).to eq([ "AC-9" ])
    expect(receipts["AC-9"]["references"].first).to include("state" => "unavailable", "reason" => "unknown_input_type")
  end

  it "cannot verify revision-bound references when the reviewed revision is unknown" do
    criteria = [ { "id" => "AC-1", "verification" => { "inputs" => [
      { "type" => "repo_path", "path" => spec_path, "commit" => head_commit, "digest" => spec_digest }
    ] } } ]
    receipts = described_class.call(
      agent_run: agent_run, repo_path: repo_path, criteria: criteria, tested_commit: nil
    )

    expect(receipts["AC-1"]["references"].first).to include(
      "state" => "unavailable", "reason" => "tested_revision_unavailable"
    )
  end
end
