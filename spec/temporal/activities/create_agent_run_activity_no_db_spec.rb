# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateAgentRunActivity, :no_db do
  describe "#attach_marketplace_entries_for_resume" do
    let(:activity) { described_class.new }
    let(:project_class) { Class.new }
    let(:user_settings_class) { Class.new }
    let(:attachments_class) do
      Class.new do
        def exists?; end
      end
    end
    let(:agent_run_class) do
      Class.new do
        def agent_run_marketplace_entries; end

        def project; end
      end
    end

    let(:project) { instance_double(project_class) }
    let(:user_settings) { instance_double(user_settings_class) }
    let(:attachments) { instance_double(attachments_class, exists?: attachments_exist) }
    let(:agent_run) do
      instance_double(
        agent_run_class,
        agent_run_marketplace_entries: attachments,
        project: project
      )
    end

    before do
      allow(activity).to receive(:marketplace_auto_attach_enabled?).with(project, user_settings).and_return(true)
      allow(MarketplaceEntries::AttachToRun).to receive(:call)
    end

    context "when the queued run already has attachment snapshots" do
      let(:attachments_exist) { true }

      it "reuses the stored snapshots instead of re-resolving marketplace entries" do
        activity.send(:attach_marketplace_entries_for_resume, agent_run:, user_settings:)

        expect(MarketplaceEntries::AttachToRun).not_to have_received(:call)
      end
    end

    context "when the queued run has not been attached yet" do
      let(:attachments_exist) { false }

      it "resolves marketplace entries once during resume" do
        activity.send(:attach_marketplace_entries_for_resume, agent_run:, user_settings:)

        expect(MarketplaceEntries::AttachToRun).to have_received(:call).with(
          agent_run: agent_run,
          manual_entry_ids: nil,
          auto_attach_enabled: true
        )
      end
    end

    context "when the provider changed during resume" do
      let(:attachments_exist) { true }

      it "re-renders marketplace attachments for the resolved provider" do
        activity.send(:attach_marketplace_entries_for_resume, agent_run:, user_settings:, force: true)

        expect(MarketplaceEntries::AttachToRun).to have_received(:call).with(
          agent_run: agent_run,
          manual_entry_ids: nil,
          auto_attach_enabled: true
        )
      end
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
          auto_attach_enabled: true
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
  end
end
