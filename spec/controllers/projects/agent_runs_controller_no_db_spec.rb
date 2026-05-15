# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::AgentRunsController, :no_db do
  describe "#attach_marketplace_entries" do
    let(:controller) { described_class.new }
    let(:agent_run) { Struct.new(:id).new(42) }

    before do
      allow(controller).to receive_messages(
        params: ActionController::Parameters.new(params_hash),
        marketplace_auto_attach_enabled_for_current_user?: true,
        marketplace_auto_attach_required_for_current_account?: account_auto_attach_required
      )
      allow(MarketplaceEntries::AttachToRun).to receive(:call).and_raise(StandardError, "render failed")
      allow(Rails.logger).to receive(:warn)
    end

    context "when the failing attachment was optional" do
      let(:params_hash) { {} }
      let(:account_auto_attach_required) { false }

      it "logs and continues" do
        expect {
          controller.send(:attach_marketplace_entries, agent_run:)
        }.not_to raise_error

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "agent_execution.marketplace_attachment_failed",
            agent_run_id: 42,
            error_class: "StandardError",
            error: "render failed"
          )
        )
      end
    end

    context "when the user manually selected marketplace entries" do
      let(:params_hash) { { marketplace_entry_ids: [ "7" ] } }
      let(:account_auto_attach_required) { false }

      it "re-raises the attachment error" do
        expect {
          controller.send(:attach_marketplace_entries, agent_run:)
        }.to raise_error(StandardError, "render failed")
      end
    end

    context "when the account requires marketplace attachments" do
      let(:params_hash) { {} }
      let(:account_auto_attach_required) { true }

      it "re-raises the attachment error" do
        expect {
          controller.send(:attach_marketplace_entries, agent_run:)
        }.to raise_error(StandardError, "render failed")
      end
    end
  end
end
