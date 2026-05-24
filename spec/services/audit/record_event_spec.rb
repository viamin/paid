# frozen_string_literal: true

require "rails_helper"

RSpec.describe Audit::RecordEvent do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  it "creates an event with an account directly" do
    event = described_class.call(
      action: "project.created",
      account: account,
      actor: user,
      metadata: { name: "test-project" }
    )

    expect(event).to be_persisted
    expect(event.action).to eq("project.created")
    expect(event.account).to eq(account)
    expect(event.actor).to eq(user)
    expect(event.metadata).to include("name" => "test-project")
  end

  it "resolves account from subject that responds to account" do
    project = create(:project, account: account)

    event = described_class.call(
      action: "project.updated",
      actor: user,
      subject: project,
      metadata: { name: project.name }
    )

    expect(event).to be_persisted
    expect(event.account).to eq(account)
  end

  it "resolves account when subject is an Account" do
    event = described_class.call(
      action: "lifecycle.suspended",
      actor: user,
      subject: account
    )

    expect(event).to be_persisted
    expect(event.account).to eq(account)
  end

  it "resolves account from subject that responds to project" do
    project = create(:project, account: account)
    agent_run = create(:agent_run, project: project, agent_type: "claude_code")

    event = described_class.call(
      action: "agent_run.created",
      actor: user,
      subject: agent_run,
      metadata: { agent_run_id: agent_run.id }
    )

    expect(event).to be_persisted
    expect(event.account).to eq(account)
  end

  it "raises when account cannot be resolved" do
    expect {
      described_class.call(action: "unknown.event", subject: Object.new)
    }.to raise_error(ArgumentError, /Cannot resolve account/)
  end

  it "logs an info message on success" do
    expect(Rails.logger).to receive(:info).with(
      hash_including(message: "audit.event_recorded", action: "project.created")
    )

    described_class.call(action: "project.created", account: account, actor: user)
  end

  it "works without an actor" do
    event = described_class.call(
      action: "project.created",
      account: account,
      metadata: { name: "test-project" }
    )

    expect(event).to be_persisted
    expect(event.actor).to be_nil
  end
end
