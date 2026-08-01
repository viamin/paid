# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectHealthCheckJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  before do
    allow(HealthChecks::Cache).to receive(:write)
    allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
  end

  it "writes the Coordinator result to the cache" do
    described_class.perform_now(project.id)

    expect(HealthChecks::Cache).to have_received(:write) do |proj, result|
      expect(proj.id).to eq(project.id)
      expect(result).to be_a(HealthChecks::Result)
      expect(result.findings).to be_an(Array)
    end
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

  it "discards silently when the project no longer exists" do
    expect { described_class.perform_now(-1) }.not_to raise_error
    expect(HealthChecks::Cache).not_to have_received(:write)
  end
end
