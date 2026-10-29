# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::RunnerReadiness do
  let(:owner) { create(:user) }
  let(:runner) { create(:runner, user: owner, runner_key: "codex") }

  # @spec LLM-ROUTING-005
  it "reports that a subscription without host tool control needs isolation" do
    readiness = described_class.call(owner: owner, operation: :chat, runner: runner.routing_key)

    expect(readiness.status).to eq("isolation_required")
  end

  # @spec LLM-ROUTING-005
  it "reports that managed subscription authentication needs isolation" do
    selected = owner.runners.find_by!(runner_key: "claude")
    create(:runner_credential, runner: selected, account: owner.account)

    readiness = described_class.call(owner: owner, operation: :chat, runner: selected.routing_key)

    expect(readiness.status).to eq("isolation_required")
  end
end
