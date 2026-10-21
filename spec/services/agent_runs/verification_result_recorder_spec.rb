# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::VerificationResultRecorder do
  # @spec LIVE-PREVIEW-005 PROJECT-READINESS-011 PROJECT-READINESS-012
  let(:project) { create(:project, screenshot_settings: { "verification_enabled" => true }) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, project: project, issue: issue) }
  let(:repo_path) { Dir.mktmpdir("verification-result-spec") }
  let(:result_path) { File.join(repo_path, AgentRuns::VerificationPrompt::RESULT_PATH) }
  let(:log_path) { File.join(repo_path, AgentRuns::VerificationPrompt::APP_LOG_PATH) }
  let(:report_artifact_payload) do
    {
      lane: "object_storage",
      kind: "generated_report",
      content_type: "application/pdf",
      storage_key: "reports/acme/widgets/pr-42/report.pdf",
      url: "https://artifacts.test/report.pdf",
      context: {
        account_id: project.account_id,
        project_id: project.id,
        agent_run_id: agent_run.id
      },
      metadata: {
        filename: "report.pdf",
        note: "Generated summary report"
      }
    }
  end
  let(:normalized_report_artifact) do
    {
      "lane" => "object_storage",
      "kind" => "generated_report",
      "content_type" => "application/pdf",
      "storage_key" => "reports/acme/widgets/pr-42/report.pdf",
      "url" => "https://artifacts.test/report.pdf",
      "context" => {
        "account_id" => project.account_id,
        "project_id" => project.id,
        "agent_run_id" => agent_run.id
      },
      "metadata" => {
        "filename" => "report.pdf",
        "note" => "Generated summary report"
      }
    }
  end

  before do
    allow(ArtifactStorage).to receive(:configured?).and_return(false)
    FileUtils.mkdir_p(File.dirname(result_path))
  end

  after do
    FileUtils.rm_rf(repo_path)
  end

  it "persists the recorded verification result and app log tail onto the run" do
    File.write(result_path, JSON.generate(
      status: "passed",
      summary: "Verified the updated settings form.",
      app_url: "http://localhost:3000/settings",
      used_browser_tools: true,
      browser_steps: [ "Opened settings", "Saved the form" ],
      artifacts: [ { kind: "app_log", path: AgentRuns::VerificationPrompt::APP_LOG_PATH } ]
    ))
    File.write(log_path, "line 1\nline 2\n")

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)

    expect(agent_run.reload.verification_result).to include(
      "status" => "passed",
      "summary" => "Verified the updated settings form.",
      "app_url" => "http://localhost:3000/settings",
      "used_browser_tools" => true,
      "browser_steps" => [ "Opened settings", "Saved the form" ],
      "app_log_tail" => "line 1\nline 2\n"
    )
    expect(File).not_to exist(result_path)
    expect(File).not_to exist(log_path)
  end

  it "preserves structured durable artifact metadata for manifest consumers" do
    File.write(result_path, JSON.generate(
      status: "passed",
      artifacts: [ report_artifact_payload ]
    ))

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result["artifacts"]).to eq([ normalized_report_artifact ])
  end

  # @spec LIVE-PREVIEW-010
  it "keeps agent-reported passes separate from recorder-owned commit and coverage evidence" do
    allow(ArtifactStorage).to receive(:configured?).and_return(false)
    File.write(result_path, JSON.generate(
      status: "passed",
      used_browser_tools: true,
      browser_steps: [ "Clicked save" ],
      acceptance_criteria: [
        { id: "AC-1", status: "passed", assertions: [ "Settings were saved" ] },
        { id: "AC-2", status: "not_run" }
      ]
    ))

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)

    result = agent_run.reload.verification_result
    expect(result).to include("status" => "passed", "reported_status" => "passed")
    expect(result.dig("evidence", "tested_commit")).to eq("a" * 40)
    expect(result.dig("evidence", "coverage")).to include(
      hash_including("id" => "AC-1", "reported_status" => "passed", "state" => "unverified"),
      hash_including("id" => "AC-2", "reported_status" => "not_run", "state" => "not_run")
    )
    expect(result.dig("evidence", "limitations")).to include("agent_reported_browser_steps_are_not_observed_evidence")
  end

  # @spec LIVE-PREVIEW-010
  it "retains reported criterion coverage when rebinding the result to the shipped commit" do
    File.write(result_path, JSON.generate(
      status: "passed",
      acceptance_criteria: [ { id: "AC-1", status: "passed", assertions: [ "Settings were saved" ] } ]
    ))

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)
    described_class.call(
      agent_run:,
      repo_path:,
      fallback_result: agent_run.reload.verification_result,
      record_missing: false,
      result_commit: "b" * 40
    )

    result = agent_run.reload.verification_result
    expect(result["reported_acceptance_criteria"]).to include(hash_including("id" => "AC-1", "status" => "passed"))
    expect(result.dig("evidence", "tested_commit")).to eq("b" * 40)
    expect(result.dig("evidence", "coverage")).to include(
      hash_including("id" => "AC-1", "reported_status" => "passed", "state" => "unverified")
    )
  end

  # @spec LIVE-PREVIEW-010
  it "rejects forged, missing, and repository-escaping reported artifact paths" do
    outside_path = File.join(Dir.tmpdir, "outside-verification-artifact.txt")
    File.write(outside_path, "outside")
    File.write(result_path, JSON.generate(
      status: "passed",
      artifacts: [
        { kind: "report", path: "missing.txt" },
        { kind: "report", path: outside_path },
        { kind: "report", storage_key: "screenshots/another-account/report.png" }
      ]
    ))

    described_class.call(agent_run:, repo_path:)

    assessments = agent_run.reload.verification_result.dig("evidence", "reported_artifact_assessments")
    expect(assessments.map { |entry| entry["state"] }).to contain_exactly("missing", "outside_repo", "untrusted_reference")
  ensure
    File.delete(outside_path) if File.exist?(outside_path)
  end

  # @spec LIVE-PREVIEW-010
  it "retains a bounded recorder-owned app log artifact with run-owned provenance" do
    storage = instance_double(ArtifactStorage, upload_io: "https://artifacts.test/verification.log")
    allow(ArtifactStorage).to receive_messages(configured?: true, new: storage)
    File.write(result_path, JSON.generate(status: "failed", reason: "browser_assertion_failed"))
    File.write(log_path, "failed browser assertion\n")

    described_class.call(agent_run:, repo_path:)

    artifact = agent_run.reload.verification_result.dig("evidence", "observed_artifacts").first
    expect(artifact).to include(
      "state" => "retained",
      "provenance" => "recorder",
      "kind" => "app_log",
      "agent_run_id" => agent_run.id
    )
    expect(artifact["storage_key"]).to include("verification/#{agent_run.id}")
  end

  # @spec LIVE-PREVIEW-010
  it "rejects a symlinked recorder-owned app log without reading or uploading it" do
    outside_dir = Dir.mktmpdir("verification-log-outside")
    outside_path = File.join(outside_dir, File.basename(log_path))
    storage = instance_double(ArtifactStorage, upload_io: "https://artifacts.test/verification.log")
    allow(ArtifactStorage).to receive_messages(configured?: true, new: storage)
    File.write(outside_path, "host-only log\n")
    File.write(result_path, JSON.generate(status: "passed"))
    FileUtils.rm_rf(File.dirname(log_path))
    File.symlink(outside_dir, File.dirname(log_path))

    described_class.call(agent_run:, repo_path:)

    result = agent_run.reload.verification_result
    expect(storage).not_to have_received(:upload_io)
    expect(result["app_log_tail"]).to be_nil
    expect(result.dig("evidence", "observed_artifacts")).to include(hash_including("state" => "inaccessible"))
    expect(File).to exist(outside_path)
  ensure
    FileUtils.rm_rf(outside_dir) if outside_dir
  end

  # @spec LIVE-PREVIEW-010
  it "marks evidence stale when the run's reviewed commit differs from the tested commit" do
    agent_run.update!(result_commit_sha: "b" * 40)
    git_status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture2e).and_return([ "c" * 40, git_status ])
    File.write(result_path, JSON.generate(status: "passed"))

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)

    expect(agent_run.reload.verification_result.dig("evidence", "freshness")).to eq(
      "state" => "stale", "reason" => "run_result_commit_changed"
    )
  end

  it "stores only the last 40 lines from a larger app log" do
    File.write(result_path, JSON.generate(status: "passed"))
    File.write(log_path, Array.new(80) { |index| "line #{index + 1}\n" }.join)

    described_class.call(agent_run:, repo_path:)

    expected_tail = Array.new(40) { |index| "line #{index + 41}\n" }.join
    expect(agent_run.reload.verification_result).to include(
      "status" => "passed",
      "app_log_tail" => expected_tail
    )
  end

  it "records a fallback status when no verification result file exists" do
    described_class.call(
      agent_run:,
      repo_path:,
      fallback_result: { "status" => "skipped", "reason" => "app_start_command_unavailable" }
    )

    expect(agent_run.reload.verification_result).to include(
      "status" => "skipped",
      "reason" => "app_start_command_unavailable"
    )
  end

  it "retains setup-failure evidence with the run revision and observation time" do
    agent_run.update!(base_commit_sha: "checkout-sha")

    described_class.call(
      agent_run:,
      repo_path:,
      fallback_result: { "status" => "skipped", "reason" => "app_start_command_unavailable" }
    )

    evidence = agent_run.reload.verification_result.fetch("readiness_observation")
    expect(evidence).to include(
      "reason" => "app_start_command_unavailable",
      "agent_run_id" => agent_run.id,
      "checkout_revision" => "checkout-sha"
    )
    expect(evidence.fetch("observed_at")).to be_present
  end

  it "keeps a browser outage run-scoped rather than treating it as readiness evidence" do
    described_class.call(
      agent_run:,
      repo_path:,
      fallback_result: { "status" => "skipped", "reason" => "browser_unavailable" }
    )

    result = agent_run.reload.verification_result
    expect(result.fetch("reason")).to eq("browser_unavailable")
    expect(result).not_to have_key("readiness_observation")
  end

  it "overwrites an existing verification result when a newer result file exists" do
    agent_run.update!(verification_result: { "status" => "failed", "reason" => "stale" })
    File.write(result_path, JSON.generate(status: "passed", summary: "Verified after resume."))

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result).to include(
      "status" => "passed",
      "summary" => "Verified after resume."
    )
  end
end
