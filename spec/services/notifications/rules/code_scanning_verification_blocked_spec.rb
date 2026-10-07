# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::CodeScanningVerificationBlocked do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, default_branch: "main") }
  let(:issue) do
    create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1838)
  end
  let(:attempt) do
    create(:code_scanning_remediation_attempt, issue: issue, pull_request_number: 4034,
      merge_commit_sha: "b" * 40, merged_at: 1.hour.ago, tool_name: "CodeQL", category: "/language:ruby",
      status: "verification_blocked", blocked_reason: "analysis is unavailable",
      verification_analysis_id: nil, verification_commit_sha: nil, verification_ref: nil,
      evidence: { "pull_request_number" => 4034 })
  end

  before { allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) }

  it "publishes a blocking notification carrying alert/PR/evidence/blocked-reason/age/next-action" do # @spec EAGER-QUEUE-016
    project.update!(last_code_scanning_scan_at: 2.hours.ago)

    expect {
        described_class.call(scope: [ attempt ])
      }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "code_scanning_verification_blocked", subject: attempt)
    expect(notification.severity).to eq("error")
    expect(notification.blocking).to be(true)
    expect(notification.metadata).to include(
      "alert_url" => issue.github_url,
      "issue_id" => issue.id,
      "attempt_id" => attempt.id,
      "pull_request_number" => 4034,
      "merge_commit_sha" => "b" * 40,
      "blocked_reason" => "analysis is unavailable",
      "last_successful_scan_at" => project.last_code_scanning_scan_at.iso8601
    )
    expect(notification.metadata["remediation_steps"]).to be_an(Array).and(be_present)
    expect(notification.action_url).to eq("/projects/#{project.id}")
  end

  it "deduplicates by (source, subject) on repeated polls" do # @spec EAGER-QUEUE-016
    described_class.call(scope: [ attempt ])
    expect {
      described_class.call(scope: [ attempt ])
    }.not_to change(Notification, :count)
  end

  it "auto-resolves the notification when the attempt transitions to verified_fixed" do # @spec EAGER-QUEUE-016
    described_class.call(scope: [ attempt ])
    attempt.update!(status: "verified_fixed")

    expect {
      described_class.call(scope: [ attempt ])
    }.to change { Notification.active.where(source: "code_scanning_verification_blocked", subject: attempt).count }.by(-1)
  end

  it "auto-resolves the notification when the attempt transitions to verification_failed" do # @spec EAGER-QUEUE-016
    described_class.call(scope: [ attempt ])
    attempt.update!(status: "verification_failed")

    expect {
      described_class.call(scope: [ attempt ])
    }.to change { Notification.active.where(source: "code_scanning_verification_blocked", subject: attempt).count }.by(-1)
  end

  it "resolves a superseded blocked attempt instead of publishing it again" do # @spec EAGER-QUEUE-016
    described_class.call(scope: [ attempt ])
    create(:code_scanning_remediation_attempt, issue: issue, pull_request_number: 4035,
      status: "verified_fixed")

    expect {
      described_class.call(scope: [ attempt ])
    }.to change { Notification.active.where(source: "code_scanning_verification_blocked", subject: attempt).count }.by(-1)
  end

  it "ignores attempts in non-blocked statuses" do # @spec EAGER-QUEUE-016
    attempt.update!(status: "verified_fixed")

    expect {
      described_class.call(scope: [ attempt ])
    }.not_to change(Notification, :count)
  end
end
