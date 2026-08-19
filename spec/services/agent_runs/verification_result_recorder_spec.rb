# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::VerificationResultRecorder do
  # @spec LIVE-PREVIEW-005
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

    described_class.call(agent_run:, repo_path:)

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
