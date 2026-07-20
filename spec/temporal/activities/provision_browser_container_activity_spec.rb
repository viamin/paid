# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ProvisionBrowserContainerActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe "#execute" do
    context "when the project has verification disabled" do
      before do
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      end

      it "returns a skipped status without invoking the provisioner" do
        expect(AgentRuns::Verification).not_to receive(:call)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:status]).to eq("skipped")
      end
    end

    context "when the project has verification enabled" do
      before do
        project.update!(screenshot_settings: { "verification_enabled" => true })
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
        allow(Containers::Provision).to receive(:network_for)
          .with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
      end

      it "delegates to AgentRuns::Verification and returns the provisioned result" do
        result_double = instance_double(
          AgentRuns::Verification::Result,
          status: "provisioned",
          container_id: "browser-abc",
          cdp_url: AgentRuns::Verification::CDP_URL
        )
        expect(AgentRuns::Verification).to receive(:call).with(
          agent_run: agent_run,
          network: NetworkPolicy::NETWORK_NAME,
          logger: anything
        ).and_return(result_double)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result).to include(
          agent_run_id: agent_run.id,
          status: "provisioned",
          container_id: "browser-abc",
          cdp_url: AgentRuns::Verification::CDP_URL
        )
      end

      it "marks configuration errors as non-retryable" do
        expect(AgentRuns::Verification).to receive(:call)
          .and_raise(AgentRuns::Verification::Error, "browser image not found: ghcr.io/browserless/chromium")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("VerificationBrowserProvisioningFailed")
          expect(error.non_retryable).to be true
        }
      end

      it "allows transient Docker errors to be retried" do
        expect(AgentRuns::Verification).to receive(:call)
          .and_raise(AgentRuns::Verification::Error, "Failed to provision verification browser container: connection refused")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("VerificationBrowserProvisioningFailed")
          expect(error.non_retryable).to be false
        }
      end

      it "marks reserved definition name conflicts as non-retryable" do
        expect(AgentRuns::Verification).to receive(:call)
          .and_raise(AgentRuns::Verification::Error, "Reserved MCP definition name playwright-mcp is already used by a non-Paid definition")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("VerificationBrowserProvisioningFailed")
          expect(error.non_retryable).to be true
        }
      end
    end
  end
end
