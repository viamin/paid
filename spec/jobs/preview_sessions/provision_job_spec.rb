# frozen_string_literal: true

require "rails_helper"

# @spec LIVE-PREVIEW-003
RSpec.describe PreviewSessions::ProvisionJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:user) { create(:user, :admin, account:) }

  it "creates an internal agent run and invokes the real preview provisioner" do
    preview_session = create(:preview_session, :provisioning, project:, account:, created_by: user, branch_name: "feature/live-preview")
    provision = instance_double(Previews::Provision, call: true)

    allow(Dir).to receive(:mktmpdir).and_yield("/tmp/paid-preview-session-spec")
    allow(Previews::Provision).to receive(:new).and_return(provision)

    expect { described_class.perform_now(preview_session.id) }.to change(AgentRun, :count).by(1)

    agent_run = preview_session.reload.agent_run
    expect(agent_run).to be_present
    expect(agent_run.agent_type).to eq("internal_agent")
    expect(agent_run).to be_synthetic
    expect(agent_run.branch_name).to eq("feature/live-preview")
    expect(agent_run.status).to eq("completed")
    expect(Previews::Provision).to have_received(:new).with(
      agent_run: agent_run,
      repo_path: "/tmp/paid-preview-session-spec",
      preview_session: have_attributes(id: preview_session.id),
      logger: Rails.logger
    )
    expect(provision).to have_received(:call)
  end

  it "transitions a queued (pending) session to provisioning when the worker picks it up" do
    preview_session = create(:preview_session, project:, account:, created_by: user, branch_name: "feature/live-preview")
    expect(preview_session).to be_pending
    provision = instance_double(Previews::Provision, call: true)

    allow(Dir).to receive(:mktmpdir).and_yield("/tmp/paid-preview-session-spec")
    allow(Previews::Provision).to receive(:new).and_return(provision)

    described_class.perform_now(preview_session.id)

    expect(preview_session.reload).to be_provisioning
    expect(Previews::Provision).to have_received(:new)
  end

  it "marks the preview session and agent run failed when provisioning raises" do
    preview_session = create(:preview_session, :provisioning, project:, account:, created_by: user)
    error = StandardError.new("preview boot failed")
    provision = instance_double(Previews::Provision, call: nil, cleanup!: true)

    allow(Dir).to receive(:mktmpdir).and_yield("/tmp/paid-preview-session-spec")
    allow(Previews::Provision).to receive(:new).and_return(provision)
    allow(provision).to receive(:call).and_raise(error)

    expect {
      expect { described_class.perform_now(preview_session.id) }.to raise_error(StandardError, "preview boot failed")
    }.to change(AgentRun, :count).by(1)

    expect(preview_session.reload).to be_failed
    expect(preview_session.error_message).to eq("preview boot failed")
    expect(preview_session.agent_run.reload.status).to eq("failed")
    expect(preview_session.agent_run.error_message).to eq("preview boot failed")
    expect(provision).to have_received(:cleanup!)
  end

  it "skips sessions that are terminal (stopped) and never provisions them" do
    preview_session = create(:preview_session, :stopped, project:, account:, created_by: user)

    allow(Previews::Provision).to receive(:new)

    expect { described_class.perform_now(preview_session.id) }.not_to change(AgentRun, :count)
    expect(Previews::Provision).not_to have_received(:new)
  end

  # @spec LIVE-PREVIEW-003
  it "does not enqueue run-quality, anomaly, or recovery jobs when the preview run finishes" do
    preview_session = create(:preview_session, :provisioning, project:, account:, created_by: user, branch_name: "feature/live-preview")
    provision = instance_double(Previews::Provision, call: true)

    allow(Dir).to receive(:mktmpdir).and_yield("/tmp/paid-preview-session-spec")
    allow(Previews::Provision).to receive(:new).and_return(provision)

    described_class.perform_now(preview_session.id)

    enqueued = ApplicationJob.queue_adapter.enqueued_jobs.map { |job| job[:job] }
    # Synthetic preview runs reuse the create_pr lifecycle to drive provisioning
    # but never execute a real agent, so finishing them must not trigger the
    # normal run-quality / anomaly / recovery followups.
    expect(enqueued).not_to include(QualityMetricsCollectionJob)
    expect(enqueued).not_to include(HumanFeedbackCollectionJob)
    expect(enqueued).not_to include(AnomalyDetectionJob)
    expect(enqueued).not_to include(FailureRecoveryDecisionJob)
  end

  it "cleans up and does not resurrect a session stopped during provisioning" do
    preview_session = create(:preview_session, :provisioning, project:, account:, created_by: user)
    provision = instance_double(Previews::Provision, cleanup!: true)

    allow(Dir).to receive(:mktmpdir).and_yield("/tmp/paid-preview-session-spec")
    allow(Previews::Provision).to receive(:new).and_return(provision)
    allow(provision).to receive(:call) do
      preview_session.mark_stopped!
    end

    described_class.perform_now(preview_session.id)

    expect(preview_session.reload).to be_stopped
    expect(provision).to have_received(:cleanup!)

    agent_run = preview_session.agent_run.reload
    expect(agent_run.status).to eq("cancelled")
    expect(agent_run).to be_finished
    expect(agent_run.completed_at).to be_present
    expect(agent_run.duration_seconds).to be >= 0
  end
end
