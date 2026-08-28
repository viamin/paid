# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::ZeroIterationTimeout do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  # @spec NOTIFICATION-SEVERITY-003
  it "publishes for a timeout with no iterations and no input tokens" do
    run = create(:agent_run, :timeout, project: project, issue: issue,
      iterations: 0, tokens_input: 0, container_id: nil)

    expect {
      described_class.call(scope: run)
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "zero_iteration_timeout", subject: run)
    expect(notification.severity).to eq("warning")
    expect(notification.metadata["duration_seconds"]).to eq(run.duration_seconds)
  end

  it "does not publish when tokens were recorded" do
    run = create(:agent_run, :timeout, project: project, issue: issue,
      iterations: 0, tokens_input: 10)

    expect {
      described_class.call(scope: run)
    }.not_to change(Notification, :count)
  end

  it "never auto-resolves" do
    run = create(:agent_run, :timeout, project: project, issue: issue,
      iterations: 0, tokens_input: 0)
    create(:notification, account: account, source: "zero_iteration_timeout", subject: run)

    described_class.call(scope: [])

    expect(Notification.find_by!(source: "zero_iteration_timeout", subject: run).resolved_at).to be_nil
  end

  it "deduplicates by run" do
    run = create(:agent_run, :timeout, project: project, issue: issue,
      iterations: 0, tokens_input: 0)

    2.times { described_class.call(scope: run) }

    expect(Notification.where(source: "zero_iteration_timeout", subject: run).count).to eq(1)
  end
end
