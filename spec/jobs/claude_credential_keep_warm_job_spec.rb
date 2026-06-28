# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClaudeCredentialKeepWarmJob do
  describe "#perform" do
    let(:mock_provision) { instance_double(Containers::Provision) }

    before do
      allow(Containers::Provision).to receive(:new).and_return(mock_provision)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:error)
    end

    context "when AgentHarness::Authentication does not expose exchange_refresh_token" do
      # exchange_refresh_token is not defined on the module, so respond_to? returns false naturally

      it "does not create a Provision instance" do
        described_class.perform_now
        expect(Containers::Provision).not_to have_received(:new)
      end

      it "logs the missing upstream API" do
        described_class.perform_now

        expect(Rails.logger).to have_received(:info).with(
          hash_including(message: "claude_credential.keep_warm.exchange_unsupported")
        )
      end
    end

    context "when exchange_refresh_token is available" do
      # exchange_refresh_token does not exist upstream yet (viamin/agent-harness#265);
      # bypass verify_partial_doubles so we can stub the future API.
      around do |example|
        without_partial_double_verification { example.run }
      end

      before do
        allow(AgentHarness::Authentication).to receive(:exchange_refresh_token)
      end

      context "when no subscription auth is present" do
        before do
          allow(mock_provision).to receive(:send).with(:claude_subscription_auth?).and_return(false)
        end

        it "logs no subscription auth" do
          described_class.perform_now

          expect(Rails.logger).to have_received(:info).with(
            hash_including(message: "claude_credential.keep_warm.no_subscription_auth")
          )
        end
      end

      context "when subscription auth is present but credential is not near expiry" do
        let(:future_expiry) { Time.now + 12.hours }

        before do
          allow(mock_provision).to receive(:send).with(:claude_subscription_auth?).and_return(true)
          allow(mock_provision).to receive(:send).with(:claude_credentials_near_expiry?).and_return(false)
          allow(mock_provision).to receive(:send).with(:claude_native_credential_expiry).and_return(future_expiry)
        end

        it "logs not near expiry" do
          described_class.perform_now

          expect(Rails.logger).to have_received(:info).with(
            hash_including(message: "claude_credential.keep_warm.not_near_expiry")
          )
        end
      end

      context "when credential is near expiry" do
        before do
          allow(mock_provision).to receive(:send).with(:claude_subscription_auth?).and_return(true)
          allow(mock_provision).to receive(:send).with(:claude_credentials_near_expiry?).and_return(true)
          allow(mock_provision).to receive(:send).with(:refresh_claude_credentials_if_near_expiry!).and_return(true)
        end

        it "calls refresh_claude_credentials_if_near_expiry! on a Provision instance" do
          described_class.perform_now

          expect(mock_provision).to have_received(:send).with(:refresh_claude_credentials_if_near_expiry!)
        end

        it "logs completion with refreshed: true" do
          described_class.perform_now

          expect(Rails.logger).to have_received(:info).with(
            hash_including(
              message: "claude_credential.keep_warm.completed",
              refreshed: true
            )
          )
        end
      end

      context "when refresh fails" do
        before do
          allow(mock_provision).to receive(:send).with(:claude_subscription_auth?).and_return(true)
          allow(mock_provision).to receive(:send).with(:claude_credentials_near_expiry?).and_return(true)
          allow(mock_provision).to receive(:send).with(:refresh_claude_credentials_if_near_expiry!).and_return(false)
        end

        it "logs completion with refreshed: false" do
          described_class.perform_now

          expect(Rails.logger).to have_received(:info).with(
            hash_including(
              message: "claude_credential.keep_warm.completed",
              refreshed: false
            )
          )
        end
      end
    end
  end
end
