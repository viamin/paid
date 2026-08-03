# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Notifications::RuleAdapter do
  let(:account) { create(:account, name: "Account #{SecureRandom.hex(4)}", slug: "account-#{SecureRandom.hex(4)}") }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:runner) { create(:runner, user: owner) }

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  def finding(**attrs)
    HealthChecks::Finding.new(
      code: :auto_merge_without_owner,
      scope: :project,
      severity: :error,
      title: "Auto-merge enabled without an owner reviewer",
      description: "Human-authored PRs will stall.",
      remediation: "Set an owner reviewer login.",
      subject_type: "Project",
      subject_id: project.id,
      metadata: {},
      **attrs
    )
  end

  def deprecated_model_finding(model_id:, tier:, subject_id: runner.id)
    finding(
      code: :deprecated_model,
      scope: :runner,
      severity: :warning,
      title: "Runner pinned to a deprecated model",
      subject_type: "Runner",
      subject_id: subject_id,
      metadata: { model_id: model_id, tier: tier }
    )
  end

  def user_finding(user:)
    finding(
      code: :missing_default_runner,
      scope: :user,
      severity: :warning,
      title: "User has no default runner",
      subject_type: "User",
      subject_id: user.id
    )
  end

  def mixed_findings(other_runner:, teammate:)
    [
      deprecated_model_finding(model_id: "gpt-4.1-mini", tier: "fast"),
      deprecated_model_finding(model_id: "gpt-4.1", tier: "deep", subject_id: other_runner.id),
      user_finding(user: owner),
      user_finding(user: teammate)
    ]
  end

  # @spec HEALTH-CHECKS-001
  it "publishes notifications for cached findings on the project health page path" do
    allow(HealthChecks::Cache).to receive(:read).with(project).and_return(
      HealthChecks::Result.new(findings: [ finding ], checked_at: Time.current, duration_ms: 5)
    )

    expect {
      described_class.call(scope: project)
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(account: account, subject: project)
    expect(notification.source).to start_with("health_check/project/#{project.id}/auto_merge_without_owner/")
    expect(notification.action_url).to eq(Rails.application.routes.url_helpers.project_health_check_path(project))
    expect(notification.nav_section).to eq("projects")
    expect(notification.description).to include("Human-authored PRs will stall.")
    expect(notification.description).to include("Set an owner reviewer login.")
  end

  # @spec HEALTH-CHECKS-002
  it "auto-resolves notifications when the cached finding disappears" do
    allow(HealthChecks::Cache).to receive(:read).with(project).and_return(
      HealthChecks::Result.new(findings: [ finding ], checked_at: Time.current, duration_ms: 5),
      HealthChecks::Result.new(findings: [], checked_at: Time.current, duration_ms: 3)
    )

    described_class.call(scope: project)

    expect {
      described_class.call(scope: project)
    }.not_to change(Notification, :count)

    expect(Notification.find_by!(account: account, subject: project).resolved_at).to be_present
  end

  # @spec HEALTH-CHECKS-003
  it "deduplicates by finding fingerprint so one runner can emit multiple notifications for the same code" do
    allow(HealthChecks::Cache).to receive(:read).with(project).and_return(
      HealthChecks::Result.new(
        findings: [
          deprecated_model_finding(model_id: "gpt-4.1-mini", tier: "fast"),
          deprecated_model_finding(model_id: "gpt-4.1", tier: "deep")
        ],
        checked_at: Time.current,
        duration_ms: 5
      )
    )

    expect {
      described_class.call(scope: project)
    }.to change(Notification, :count).by(2)

    expect(Notification.where(account: account, subject: runner).pluck(:source).uniq.size).to eq(2)
  end

  # @spec HEALTH-CHECKS-001
  it "batches subject lookups per table when syncing mixed findings" do
    teammate = create(:user, account: account)
    other_runner = create(:runner, user: teammate, runner_key: "codex")

    allow(HealthChecks::Cache).to receive(:read).with(project).and_return(
      HealthChecks::Result.new(
        findings: mixed_findings(other_runner:, teammate:),
        checked_at: Time.current,
        duration_ms: 5
      )
    )
    allow(Notifications::Publish).to receive(:call)
    allow(Notifications::Resolve).to receive(:call)

    queries = capture_queries do
      described_class.call(scope: project)
    end

    expect(queries.count { |sql| sql.include?('FROM "runners"') }).to eq(1)
    expect(queries.count { |sql| sql.include?('FROM "users"') }).to eq(1)
  end
end
