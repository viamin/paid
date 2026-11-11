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
  let(:criterion_report) do
    [
      {
        id: "AC-1", status: "passed", assertions: [ "Settings were saved" ],
        verification: {
          kind: "permanent_system_test",
          references: [ { locator: "spec/system/settings_spec.rb:42", result: "passed" } ]
        }
      },
      {
        id: "AC-2", status: "skipped",
        verification: {
          kind: "ephemeral_system_test",
          references: [ { locator: ".ephemeral-tests/settings_spec.rb:18", result: "skipped", reason: "ephemeral_job_skipped" } ]
        }
      },
      { id: "AC-3", status: "not_run", verification: { kind: "browser_flow" } },
      {
        id: "AC-4", status: "failed",
        verification: {
          kind: "unit_or_service_test",
          references: [ { locator: "spec/services/models_spec.rb:27", result: "failed" } ]
        }
      }
    ]
  end

  before do
    allow(ArtifactStorage).to receive(:configured?).and_return(false)
    FileUtils.mkdir_p(File.dirname(result_path))
  end

  after do
    FileUtils.rm_rf(repo_path)
  end

  def expect_criterion_coverage(result)
    expect(result.dig("evidence", "coverage")).to include(
      hash_including(
        "id" => "AC-1", "reported_status" => "passed", "state" => "unverified",
        "reported_verification" => hash_including("kind" => "permanent_system_test")
      ),
      hash_including("id" => "AC-2", "reported_status" => "skipped", "state" => "skipped", "reason" => "reported_skipped"),
      hash_including("id" => "AC-3", "reported_status" => "not_run", "state" => "not_run"),
      hash_including("id" => "AC-4", "reported_status" => "failed", "state" => "contradicted", "reason" => "reported_failure")
    )
  end

  def write_verification_result(payload)
    File.write(result_path, JSON.generate(payload))
  end

  def input_receipt_for(result)
    result.dig("evidence", "coverage").sole.fetch("input_receipt")
  end

  def repository_receipt_payload(digest)
    {
      status: "passed",
      acceptance_criteria: [ {
        id: "AC-1", status: "passed",
        verification: {
          kind: "permanent_system_test", rationale: "Exercises settings persistence.",
          limitations: [ "Does not prove all settings variants." ],
          inputs: [ { type: "repository_file", path: "spec/system/settings_spec.rb", revision: "a" * 40, digest: } ]
        }
      } ]
    }
  end

  def artifact_receipt_payload(storage_key)
    {
      status: "passed",
      acceptance_criteria: [ {
        id: "AC-1", status: "passed",
        verification: {
          kind: "unit_or_service_test", rationale: "The retained log records the exercised request.",
          inputs: [ { type: "artifact", storage_key: } ]
        }
      } ]
    }
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
      "app_log_tail" => "line 1\nline 2\n", "app_log_truncated" => false
    )
    expect(File).not_to exist(result_path)
    expect(File).not_to exist(log_path)
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "preserves a captured application log written after the run was loaded" do
    stale_agent_run = AgentRun.find(agent_run.id)
    agent_run.project.update!(verification_enabled: true)
    agent_run.update!(status: "running")
    AgentRuns::CaptureApplicationLog.call(agent_run:, content: "captured while verifying")
    File.write(result_path, JSON.generate(status: "passed"))

    described_class.call(agent_run: stale_agent_run, repo_path:)

    expect(agent_run.reload.verification_result).to include(
      "status" => "passed",
      "app_log_tail" => "captured while verifying"
    )
  end

  it "preserves structured durable artifact metadata for manifest consumers" do
    File.write(result_path, JSON.generate(
      status: "passed",
      artifacts: [ report_artifact_payload ]
    ))

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result["artifacts"]).to eq([ normalized_report_artifact ])
  end

  # @spec LIVE-PREVIEW-010 LIVE-PREVIEW-011
  it "keeps agent-reported passes separate from recorder-owned commit and coverage evidence" do
    allow(ArtifactStorage).to receive(:configured?).and_return(false)
    File.write(result_path, JSON.generate(
      status: "passed",
      used_browser_tools: true,
      browser_steps: [ "Clicked save" ],
      acceptance_criteria: criterion_report
    ))

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)

    result = agent_run.reload.verification_result
    expect(result).to include("status" => "passed", "reported_status" => "passed")
    expect(result.dig("evidence", "tested_commit")).to eq("a" * 40)
    expect_criterion_coverage(result)
    expect(result.dig("evidence", "limitations")).to include("agent_reported_browser_steps_are_not_observed_evidence")
  end

  # @spec LIVE-PREVIEW-013
  it "records a mechanically verified repository input without promoting semantic coverage" do
    path = File.join(repo_path, "spec", "system", "settings_spec.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "RSpec.describe 'settings' do; end\n")
    digest = Digest::SHA256.file(path).hexdigest
    write_verification_result(repository_receipt_payload(digest))

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)

    result = agent_run.reload.verification_result
    coverage = result.dig("evidence", "coverage").sole
    expect(coverage).to include("state" => "unverified")
    expect(coverage.fetch("reported_verification")).to include(
      "rationale" => "Exercises settings persistence.",
      "limitations" => [ "Does not prove all settings variants." ]
    )
    expect(coverage.dig("input_receipt", "state")).to eq("verified")
    expect(coverage.dig("input_receipt", "references", 0)).to include("state" => "verified", "path" => "spec/system/settings_spec.rb")
    expect(result.dig("evidence", "criterion_receipt_pilot")).to include(
      "false_claims_caught" => 0,
      "valid_claims_rejected" => { "state" => "unavailable", "reason" => "requires_human_adjudication" },
      "review_usefulness" => { "state" => "unavailable", "reason" => "requires_reviewer_feedback" }
    )
  end

  # @spec LIVE-PREVIEW-013
  it "labels fabricated, stale, skipped, and unavailable criterion inputs without issuing a receipt" do
    write_verification_result(
      status: "passed",
      acceptance_criteria: [ {
        id: "AC-1", status: "passed",
        verification: {
          kind: "unit_or_service_test", rationale: "Reported inputs.",
          inputs: [
            { type: "repository_file", path: "spec/missing_spec.rb", revision: "a" * 40, digest: "0" * 64 },
            { type: "repository_file", path: "spec/stale_spec.rb", revision: "b" * 40, digest: "0" * 64 },
            { type: "test_run", command: "bin/rspec spec/services/x_spec.rb", result: "skipped" },
            { type: "artifact", storage_key: "verification/missing.log" }
          ]
        }
      } ]
    )

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)

    receipt = input_receipt_for(agent_run.reload.verification_result)
    expect(receipt.fetch("state")).to eq("contradicted")
    expect(receipt.fetch("references").map { |reference| reference.fetch("state") }).to eq(%w[contradicted stale contradicted unavailable])
  end

  # @spec LIVE-PREVIEW-011
  it "persists criterion evidence without browser evidence when interactive verification is disabled" do
    project.update!(screenshot_settings: { "verification_enabled" => false })
    File.write(result_path, JSON.generate(
      status: "passed",
      app_url: "http://localhost:3000/settings",
      used_browser_tools: true,
      browser_steps: [ "Clicked save" ],
      acceptance_criteria: criterion_report
    ))

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)

    result = agent_run.reload.verification_result
    expect(result).to include("status" => "passed", "reported_status" => "passed")
    expect_criterion_coverage(result)
    expect(result).not_to include("app_url", "used_browser_tools", "browser_steps")
    expect(result.dig("evidence", "runtime_configuration")).to be_nil
    expect(result.dig("evidence", "observed_artifacts")).to be_nil
  end

  # @spec LIVE-PREVIEW-011
  it "records missing criterion evidence when interactive verification is disabled" do
    project.update!(screenshot_settings: { "verification_enabled" => false })

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result).to include(
      "status" => "not_run",
      "reason" => "verification_result_missing"
    )
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

  # @spec LIVE-PREVIEW-013
  it "retains a verified artifact receipt when rebinding after transient files are cleaned up" do
    storage = instance_double(ArtifactStorage, upload_io: "https://artifacts.test/verification.log")
    allow(ArtifactStorage).to receive_messages(configured?: true, new: storage)
    storage_key = "#{Screenshots::Storage.namespace_prefix(org: project.owner, repo: project.repo)}verification/#{agent_run.id}/#{"a" * 40}/app.log"
    write_verification_result(artifact_receipt_payload(storage_key))
    File.write(log_path, "request completed\n")

    described_class.call(agent_run:, repo_path:, result_commit: "a" * 40)
    first_result = agent_run.reload.verification_result
    expect(input_receipt_for(first_result)).to include("state" => "verified")

    described_class.call(
      agent_run:,
      repo_path:,
      fallback_result: first_result,
      record_missing: false,
      result_commit: "b" * 40
    )

    receipt = input_receipt_for(agent_run.reload.verification_result)
    expect(receipt).to include("state" => "verified")
    expect(receipt.fetch("references").sole).to include(
      "storage_key" => storage_key, "state" => "verified", "provenance" => "recorder"
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
      "app_log_tail" => expected_tail,
      "app_log_truncated" => true
    )
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-001
  it "flags the persisted tail as complete when the agent log fits within the caps" do
    File.write(result_path, JSON.generate(status: "passed"))
    File.write(log_path, "single entry\n")

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result).to include("app_log_truncated" => false)
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-001
  it "flags the persisted tail as truncated when the byte cap stops the read" do
    File.write(result_path, JSON.generate(status: "passed"))
    File.write(log_path, "x" * (described_class::LOG_TAIL_MAX_BYTES + 1))

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result).to include(
      "app_log_truncated" => true,
      "app_log_tail" => "x" * described_class::LOG_TAIL_MAX_BYTES
    )
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-001
  it "bounds redacted content that expands beyond the log byte cap" do
    File.write(result_path, JSON.generate(status: "passed"))
    File.write(log_path, "a@b.co " * (described_class::LOG_TAIL_MAX_BYTES / 7))

    described_class.call(agent_run:, repo_path:)

    result = agent_run.reload.verification_result
    expect(result.fetch("app_log_tail").bytesize).to be <= described_class::LOG_TAIL_MAX_BYTES
    expect(result).to include("app_log_truncated" => true)
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "falls back to the agent-captured `app_log_truncated` marker when no on-disk log is readable" do
    agent_run.update!(verification_result: {
      "app_log_tail" => "captured during verification",
      "app_log_truncated" => true,
      "app_log_recorded_at" => "2026-10-21T00:00:00Z"
    })
    File.write(result_path, JSON.generate(status: "passed"))

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result).to include(
      "app_log_tail" => "captured during verification",
      "app_log_truncated" => true,
      "app_log_recorded_at" => "2026-10-21T00:00:00Z"
    )
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-001
  it "redacts secrets before persisting the app log tail" do
    File.write(result_path, JSON.generate(status: "passed"))
    File.write(log_path, "boot token=super-secret-value\n")

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result.fetch("app_log_tail")).to include("[REDACTED")
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-001
  it "redacts active account credentials from the final app log tail" do
    credential = create(:integration_credential, account: agent_run.project.account, secret: "stagingpassword")
    File.write(result_path, JSON.generate(status: "passed"))
    File.write(log_path, "upstream denied credential: #{credential.secret}\n")

    described_class.call(agent_run:, repo_path:)

    persisted_log = agent_run.reload.verification_result.fetch("app_log_tail")
    expect(persisted_log).to include("[REDACTED:known_secret]")
    expect(persisted_log).not_to include(credential.secret)
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "retains the active-run captured log when the final log file is unavailable" do
    agent_run.update!(verification_result: {
      "app_log_tail" => "captured during verification",
      "app_log_recorded_at" => "2026-10-21T00:00:00Z"
    })
    File.write(result_path, JSON.generate(status: "passed"))

    described_class.call(agent_run:, repo_path:)

    expect(agent_run.reload.verification_result).to include(
      "app_log_tail" => "captured during verification",
      "app_log_recorded_at" => "2026-10-21T00:00:00Z"
    )
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "retains the active-run captured log on the apple-gate path when the agent wrote no result" do
    FeatureFlags.enable!(:apple_verification_workers, project:)
    project.update!(apple_verification_mode: "on_demand")
    revision = create(:apple_verification_workflow_revision, :approved, project:,
      lifecycle_gate: "pull_request_verification", required_checks: %w[ios-app.tests])
    agent_run.update!(verification_result: {
      "app_log_tail" => "captured during verification",
      "app_log_recorded_at" => "2026-10-21T00:00:00Z", "app_log_truncated" => true
    })

    described_class.call(agent_run:, repo_path:)

    result = agent_run.reload.verification_result
    expect(result).to include(
      "app_log_tail" => "captured during verification",
      "app_log_recorded_at" => "2026-10-21T00:00:00Z", "app_log_truncated" => true
    )
    expect(result).to include("status" => "not_run", "reason" => "apple_verification_pending")
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
