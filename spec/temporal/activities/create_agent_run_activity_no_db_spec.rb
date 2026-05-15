# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateAgentRunActivity, :no_db do
  describe "#attach_marketplace_entries_for_resume" do
    let(:activity) { described_class.new }
    let(:user_settings_class) do
      Class.new do
        def marketplace_auto_attach_enabled?; end
      end
    end
    let(:attachments_class) do
      Class.new do
        def exists?(*); end
      end
    end
    let(:user_settings) { instance_double(user_settings_class) }

    before do
      allow(activity).to receive(:marketplace_auto_attach_enabled?).with(user_settings).and_return(true)
      allow(MarketplaceEntries::AttachToRun).to receive(:call)
      allow(MarketplaceEntries::RerenderForRun).to receive(:call)
    end

    context "when the queued run already has attachment snapshots" do
      it "reuses the stored snapshots instead of re-resolving marketplace entries" do
        agent_run = build_agent_run(attachments_exist: true)

        activity.send(:attach_marketplace_entries_for_resume, agent_run:, user_settings:, account_auto_attach_required: false)

        expect(MarketplaceEntries::AttachToRun).not_to have_received(:call)
      end
    end

    context "when the queued run has not been attached yet" do
      it "resolves marketplace entries once during resume" do
        agent_run = build_agent_run(attachments_exist: false)

        activity.send(:attach_marketplace_entries_for_resume, agent_run:, user_settings:, account_auto_attach_required: false)

        expect(MarketplaceEntries::AttachToRun).to have_received(:call).with(
          agent_run: agent_run,
          manual_entry_ids: nil,
          auto_attach_enabled: true,
          account_auto_attach_required: false
        )
      end
    end

    context "when the provider changed during resume" do
      it "re-renders the stored marketplace snapshots for the resolved provider" do
        agent_run = build_agent_run(attachments_exist: true)

        activity.send(:attach_marketplace_entries_for_resume, agent_run:, user_settings:, force: true, account_auto_attach_required: false)

        expect(MarketplaceEntries::AttachToRun).not_to have_received(:call)
        expect(MarketplaceEntries::RerenderForRun).to have_received(:call).with(agent_run: agent_run)
      end
    end

    def build_agent_run(attachments_exist:)
      project = Struct.new(:account).new(:account)
      attachments = instance_double(attachments_class)
      allow(attachments).to receive(:exists?).with(no_args).and_return(attachments_exist)
      allow(attachments).to receive(:exists?).with(attachment_source: "team_default").and_return(attachments_exist)

      Struct.new(:agent_run_marketplace_entries, :project).new(attachments, project)
    end
  end

  describe "#attach_marketplace_entries" do
    let(:activity) { described_class.new }
    let(:agent_run) { Struct.new(:id).new(42) }
    let(:logger) { instance_double(Logger, warn: nil) }

    it "logs and swallows marketplace attachment errors" do
      allow(activity).to receive(:logger).and_return(logger)
      allow(MarketplaceEntries::AttachToRun).to receive(:call).and_raise(StandardError, "render failed")

      expect {
        activity.send(
          :attach_marketplace_entries,
          agent_run: agent_run,
          manual_entry_ids: [ 7 ],
          auto_attach_enabled: true,
          account_auto_attach_required: false
        )
      }.not_to raise_error

      expect(logger).to have_received(:warn).with(
        hash_including(
          message: "agent_execution.marketplace_attachment_failed",
          agent_run_id: 42,
          error_class: "StandardError",
          error: "render failed"
        )
      )
    end

    it "re-raises marketplace attachment errors when the account requires marketplace defaults" do
      allow(activity).to receive(:logger).and_return(logger)
      allow(MarketplaceEntries::AttachToRun).to receive(:call).and_raise(StandardError, "render failed")

      expect {
        activity.send(
          :attach_marketplace_entries,
          agent_run: agent_run,
          auto_attach_enabled: true,
          account_auto_attach_required: true
        )
      }.to raise_error(StandardError, "render failed")
    end
  end

  describe "#rerender_marketplace_entries" do
    let(:activity) { described_class.new }
    let(:agent_run) { Struct.new(:id).new(42) }
    let(:logger) { instance_double(Logger, warn: nil) }

    it "re-raises rerender errors when required marketplace attachments must be preserved" do
      allow(activity).to receive(:logger).and_return(logger)
      allow(MarketplaceEntries::RerenderForRun).to receive(:call).and_raise(StandardError, "rerender failed")

      expect {
        activity.send(:rerender_marketplace_entries, agent_run: agent_run, required: true)
      }.to raise_error(StandardError, "rerender failed")
    end
  end
end
