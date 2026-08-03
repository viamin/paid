# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Notifications::RuleAdapter do
  let(:account) { create(:account, name: "Account #{SecureRandom.hex(4)}", slug: "account-#{SecureRandom.hex(4)}") }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:runner) { create(:runner, user: owner) }
  let(:rule_class) { described_class.for(HealthChecks::Checks::Project::AutoMergeWithoutOwner) }

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

  def sync_rule(check_class:, project_results:)
    described_class.for(check_class).call(scope: account, health_check_results_by_project_id: project_results)
  end

  describe ".for" do
    it "returns an anonymous rule subclass bound to the check class" do
      expect(rule_class.superclass).to eq(described_class)
      expect(rule_class.check_class).to eq(HealthChecks::Checks::Project::AutoMergeWithoutOwner)
    end
  end

  # @spec HEALTH-CHECKS-001
  it "publishes notifications for cached findings on the project health page path" do
    result = HealthChecks::Result.new(findings: [ finding ], checked_at: Time.current, duration_ms: 5)

    expect {
      sync_rule(check_class: HealthChecks::Checks::Project::AutoMergeWithoutOwner, project_results: { project.id => result })
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
    result = HealthChecks::Result.new(findings: [ finding ], checked_at: Time.current, duration_ms: 5)
    sync_rule(check_class: HealthChecks::Checks::Project::AutoMergeWithoutOwner, project_results: { project.id => result })

    cleared = HealthChecks::Result.new(findings: [], checked_at: Time.current, duration_ms: 3)

    expect {
      sync_rule(check_class: HealthChecks::Checks::Project::AutoMergeWithoutOwner, project_results: { project.id => cleared })
    }.not_to change(Notification, :count)

    expect(Notification.find_by!(account: account, subject: project).resolved_at).to be_present
  end

  it "leaves existing notifications intact on a transient cache miss" do
    allow(HealthChecks::Cache).to receive(:read).with(project).and_return(
      HealthChecks::Result.new(findings: [ finding ], checked_at: Time.current, duration_ms: 5)
    )
    rule_class.call(scope: project)
    notification = Notification.find_by!(account: account, subject: project)

    allow(HealthChecks::Cache).to receive(:read).with(project).and_return(nil)

    expect {
      rule_class.call(scope: project)
    }.not_to change { notification.reload.resolved_at }

    expect(notification.resolved_at).to be_nil
  end

  # @spec HEALTH-CHECKS-003
  it "deduplicates by finding fingerprint so one runner can emit multiple notifications for the same code" do
    result = HealthChecks::Result.new(
      findings: [
        deprecated_model_finding(model_id: "gpt-4.1-mini", tier: "fast"),
        deprecated_model_finding(model_id: "gpt-4.1", tier: "deep")
      ],
      checked_at: Time.current,
      duration_ms: 5
    )

    expect {
      sync_rule(check_class: HealthChecks::Checks::Runner::DeprecatedModel, project_results: { project.id => result })
    }.to change(Notification, :count).by(2)

    expect(Notification.where(account: account, subject: runner).pluck(:source).uniq.size).to eq(2)
  end

  it "batches subject lookups per table when syncing mixed findings" do
    teammate = create(:user, account: account)
    other_runner = create(:runner, user: teammate, runner_key: "codex")
    result = HealthChecks::Result.new(
      findings: [
        deprecated_model_finding(model_id: "gpt-4.1-mini", tier: "fast"),
        deprecated_model_finding(model_id: "gpt-4.1", tier: "deep", subject_id: other_runner.id),
        user_finding(user: owner),
        user_finding(user: teammate)
      ],
      checked_at: Time.current,
      duration_ms: 5
    )
    allow(Notifications::Publish).to receive(:call)
    allow(Notifications::Resolve).to receive(:call)

    queries = capture_queries do
      sync_rule(check_class: HealthChecks::Checks::Runner::DeprecatedModel, project_results: { project.id => result })
      sync_rule(check_class: HealthChecks::Checks::User::MissingDefaultRunner, project_results: { project.id => result })
    end

    expect(queries.count { |sql| sql.include?('FROM "runners"') }).to eq(1)
    expect(queries.count { |sql| sql.include?('FROM "users"') }).to eq(1)
  end

  it "preserves the original subject identity when the subject row has been deleted" do
    result = HealthChecks::Result.new(
      findings: [ deprecated_model_finding(model_id: "gpt-4.1-mini", tier: "fast") ],
      checked_at: Time.current,
      duration_ms: 5
    )

    sync_rule(check_class: HealthChecks::Checks::Runner::DeprecatedModel, project_results: { project.id => result })
    runner_id = runner.id
    existing_source = Notification.last.source
    runner.destroy!

    expect {
      sync_rule(check_class: HealthChecks::Checks::Runner::DeprecatedModel, project_results: { project.id => result })
    }.not_to change(Notification, :count)

    notification = Notification.find_by!(account: account, source: existing_source)
    expect(notification.subject_type).to eq("Runner")
    expect(notification.subject_id).to eq(runner_id)
    expect(notification.subject).to be_nil
  end

  it "resolves stale notifications even when the original subject row has been deleted" do
    source = "health_check/project/#{project.id}/deprecated_model/Runner/#{runner.id}/abc123def456"
    create(:notification, account: account, source: source, subject: runner)
    runner.destroy!

    cleared = HealthChecks::Result.new(findings: [], checked_at: Time.current, duration_ms: 5)
    sync_rule(check_class: HealthChecks::Checks::Runner::DeprecatedModel, project_results: { project.id => cleared })

    notification = Notification.find_by!(account: account, source: source)
    expect(notification.resolved_at).to be_present
    expect(notification.subject_type).to eq("Runner")
    expect(notification.subject_id).to eq(runner.id)
  end

  it "publishes an internal-error notification when the cached sweep result captured a check failure" do
    source = "health_check/project/#{project.id}/auto_merge_without_owner/Project/#{project.id}/abc123def456"
    create(:notification, account: account, source: source, subject: project)
    error_finding = HealthChecks::Coordinator.internal_error_finding(
      check_class: HealthChecks::Checks::Project::AutoMergeWithoutOwner,
      subject: project,
      error: RuntimeError.new("boom")
    )
    result = HealthChecks::Result.new(findings: [ error_finding ], checked_at: Time.current, duration_ms: 5)

    sync_rule(check_class: HealthChecks::Checks::Project::AutoMergeWithoutOwner, project_results: { project.id => result })

    stale_notification = Notification.find_by!(account: account, source: source, subject: project)
    expect(stale_notification.resolved_at).to be_present

    internal_notification = Notification.active.find_by!(
      account: account,
      title: "Internal health check error",
      subject: project
    )
    expect(internal_notification.description).to include("RuntimeError: boom")
  end

  describe ".evaluate_all integration" do
    before do
      Notifications::Rule.register(described_class.for(HealthChecks::Checks::Project::AutoMergeWithoutOwner))
    end

    after do
      Notifications::Rule.rule_classes.clear
    end

    it "publishes notifications for all registered rules" do
      result = HealthChecks::Result.new(findings: [ finding ], checked_at: Time.current, duration_ms: 5)

      expect {
        Notifications::Rule.evaluate_all(
          account: account,
          health_check_results_by_project_id: { project.id => result }
        )
      }.to change(Notification, :count).by(1)
    end
  end
end
