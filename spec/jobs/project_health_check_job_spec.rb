# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectHealthCheckJob do
  let(:account) do
    create(:account, name: "Account #{SecureRandom.hex(4)}", slug: "account-#{SecureRandom.hex(4)}")
  end
  let(:token_creator) { create(:user, account: account, email: "token-#{SecureRandom.hex(6)}@example.com") }
  let(:project_owner) { create(:user, account: account, email: "owner-#{SecureRandom.hex(6)}@example.com") }
  let(:github_token) do
    create(:github_token, account: account, created_by: token_creator, name: "Token #{SecureRandom.hex(4)}")
  end
  let(:project) do
    create(
      :project,
      account: account,
      created_by: project_owner,
      github_token: github_token,
      owner: "owner-#{SecureRandom.hex(4)}",
      repo: "repo-#{SecureRandom.hex(4)}"
    )
  end

  before do
    allow(HealthChecks::Cache).to receive(:write)
    allow(HealthChecks::Notifications::RuleAdapter).to receive(:call)
    allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
  end

  it "writes the Coordinator result to the cache" do
    described_class.perform_now(project.id)

    expect(HealthChecks::Cache).to have_received(:write) do |proj, result|
      expect(proj.id).to eq(project.id)
      expect(result).to be_a(HealthChecks::Result)
      expect(result.findings).to be_an(Array)
    end
    expect(HealthChecks::Notifications::RuleAdapter).to have_received(:call).with(scope: project)
  end

  it "emits a structured completion log with findings count and duration" do
    allow(Rails.logger).to receive(:info)

    described_class.perform_now(project.id)

    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "project_health.check_completed",
        project_id: project.id,
        findings_count: an_instance_of(Integer),
        duration_ms: an_instance_of(Integer)
      )
    )
  end

  it "broadcasts the fresh result via Turbo Streams so the page auto-refreshes" do
    described_class.perform_now(project.id)

    expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
      [ project, :health_checks ],
      hash_including(
        target: "health_check_result",
        partial: "projects/health_check/result"
      )
    )
  end

  # The broadcast renders its partial through ApplicationController's view
  # context, which does not see controller-specific helper_methods. Rendering
  # the partial the same way the broadcast does must not raise (RDR-049).
  it "renders the result partial in the broadcast view context without raising" do
    allow(HealthChecks::Coordinator).to receive(:call)
      .and_return(HealthChecks::Result.new(
        findings: [ HealthChecks::Finding.new(
          code: :empty_allowlist, scope: :project, severity: :error,
          title: "Trusted usernames allowlist is empty",
          description: "d", remediation: "r"
        ) ],
        checked_at: Time.current, duration_ms: 10
      ))

    captured = nil
    allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) do |_stream, opts|
      captured = opts
    end

    described_class.perform_now(project.id)

    rendered = ApplicationController.render(
      partial: captured.fetch(:partial),
      locals: captured.fetch(:locals)
    )
    expect(rendered).to include("Trusted usernames allowlist is empty")
    expect(rendered).to include(Projects::HealthCheckHelper::SUMMARY_BADGE[:error])
  end

  # The structured completion log must be emitted before the broadcast so a
  # transient broadcast failure cannot swallow the completion metric.
  it "logs completion before broadcasting the result" do
    events = []
    allow(Rails.logger).to receive(:info) do |payload|
      events << :logged if payload.is_a?(Hash) && payload[:message] == "project_health.check_completed"
    end
    allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) { events << :broadcast }

    described_class.perform_now(project.id)

    expect(events).to eq([ :logged, :broadcast ])
  end

  it "logs completion and still broadcasts when notification sync fails" do
    allow(HealthChecks::Notifications::RuleAdapter).to receive(:call).and_raise("notify boom")
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)

    described_class.perform_now(project.id)

    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "project_health.check_completed", project_id: project.id)
    )
    expect(Rails.logger).to have_received(:warn).with(
      hash_including(message: "project_health.notification_sync_failed", project_id: project.id, error: "notify boom")
    )
    expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to)
  end

  it "discards silently when the project no longer exists" do
    expect { described_class.perform_now(-1) }.not_to raise_error
    expect(HealthChecks::Cache).not_to have_received(:write)
  end
end
