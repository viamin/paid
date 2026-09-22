# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-NETWORK-001
RSpec.describe AgentRuns::AppleVerification::ResolveGuestContract do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe ".call" do
    context "when apple_verification_workers is disabled" do
      it "raises WorkersDisabledError without touching the run's egress policy" do
        expect { described_class.call(agent_run: agent_run) }
          .to raise_error(described_class::WorkersDisabledError)

        expect(agent_run.reload.external_metadata).not_to have_key("egress_policy")
      end
    end

    context "when apple_verification_workers is enabled for the project" do
      before { FeatureFlags.enable!(:apple_verification_workers, project: project) }

      it "resolves and persists a proxy-restricted egress snapshot" do
        described_class.call(agent_run: agent_run)

        snapshot = AgentRuns::EgressPolicy::Snapshot.from_record(agent_run.reload)
        expect(snapshot.mode).to eq("proxy_only")
        expect(snapshot.egress_profile).to eq("locked")
      end

      it "returns a credential-free guest contract built from the snapshot" do
        contract = described_class.call(agent_run: agent_run)

        expect(contract.dns).to eq("paid")
        expect(contract.proxy).to include(:host, :port)
        expect(contract.proxy.to_s).not_to match(/@|token|password/i)
        expect(contract.destinations).to include(hash_including(host: "egress-gateway"))
      end
    end
  end
end
