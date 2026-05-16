# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::AgentRunsController, :no_db do
  describe "#copy_marketplace_attachments" do
    let(:controller) { described_class.new }

    before do
      allow(MarketplaceEntries::RerenderForRun).to receive(:call)
    end

    def build_copy_attachment_context(attachments)
      ordered_relation = double(to_a: attachments)
      included_relation = double(ordered: ordered_relation)
      source_relation = double(includes: included_relation)
      target_association = double
      source_run = double(agent_run_marketplace_entries: source_relation)
      target_run = double(agent_run_marketplace_entries: target_association)

      {
        target_association: target_association,
        source_run: source_run,
        target_run: target_run
      }
    end

    def rendered_payload
      {
        "provider" => "claude",
        "provider_format" => "claude_skill_v1",
        "attachment_strategy" => "prompt_append",
        "payload" => { "content" => "Follow the marketplace workflow." }
      }
    end

    def build_attachment(entry:, version:)
      Struct.new(
        :marketplace_entry,
        :marketplace_entry_version,
        :attachment_source,
        :position,
        :selection_reason,
        :rendered_format,
        :rendered_payload,
        keyword_init: true
      ).new(
        marketplace_entry: entry,
        marketplace_entry_version: version,
        attachment_source: "manual",
        position: 2,
        selection_reason: "Selected manually for this run",
        rendered_format: "claude_skill_v1",
        rendered_payload: rendered_payload
      )
    end

    it "copies snapshot attachments to the new run and re-syncs MCP state" do
      entry = Object.new
      version = Object.new
      attachment = build_attachment(entry:, version:)
      context = build_copy_attachment_context([ attachment ])

      expect(context[:target_association]).to receive(:create!).with(
        marketplace_entry: entry,
        marketplace_entry_version: version,
        attachment_source: "manual",
        position: 2,
        selection_reason: "Selected manually for this run",
        rendered_format: "claude_skill_v1",
        rendered_payload: rendered_payload
      )

      controller.send(
        :copy_marketplace_attachments,
        source_run: context[:source_run],
        target_run: context[:target_run]
      )

      expect(MarketplaceEntries::RerenderForRun).to have_received(:call).with(agent_run: context[:target_run])
    end

    it "does nothing when the source run has no marketplace attachments" do
      context = build_copy_attachment_context([])

      expect(context[:target_association]).not_to receive(:create!)

      controller.send(
        :copy_marketplace_attachments,
        source_run: context[:source_run],
        target_run: context[:target_run]
      )

      expect(MarketplaceEntries::RerenderForRun).not_to have_received(:call)
    end
  end

  describe "#attach_marketplace_entries" do
    let(:controller) { described_class.new }
    let(:agent_run) { Struct.new(:id).new(42) }

    before do
      allow(controller).to receive_messages(
        params: ActionController::Parameters.new(params_hash),
        marketplace_auto_attach_enabled_for_current_user?: true,
        marketplace_auto_attach_required_for_current_account?: account_auto_attach_required
      )
      allow(Rails.logger).to receive(:warn)
    end

    context "when the failing attachment was optional" do
      let(:params_hash) { {} }
      let(:account_auto_attach_required) { false }

      it "logs and continues for ignorable attachment errors" do
        allow(MarketplaceEntries::AttachToRun).to receive(:call).and_raise(ActiveRecord::RecordNotFound, "missing entry")

        expect {
          controller.send(:attach_marketplace_entries, agent_run:)
        }.not_to raise_error

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "agent_execution.marketplace_attachment_failed",
            agent_run_id: 42,
            error_class: "ActiveRecord::RecordNotFound",
            error: "missing entry"
          )
        )
      end

      it "re-raises unexpected attachment errors" do
        allow(MarketplaceEntries::AttachToRun).to receive(:call).and_raise(StandardError, "render failed")

        expect {
          controller.send(:attach_marketplace_entries, agent_run:)
        }.to raise_error(StandardError, "render failed")
      end
    end

    context "when the user manually selected marketplace entries" do
      let(:params_hash) { { marketplace_entry_ids: [ "7" ] } }
      let(:account_auto_attach_required) { false }

      it "re-raises the attachment error" do
        allow(MarketplaceEntries::AttachToRun).to receive(:call).and_raise(StandardError, "render failed")

        expect {
          controller.send(:attach_marketplace_entries, agent_run:)
        }.to raise_error(StandardError, "render failed")
      end
    end

    context "when the account requires marketplace attachments" do
      let(:params_hash) { {} }
      let(:account_auto_attach_required) { true }

      it "re-raises the attachment error" do
        allow(MarketplaceEntries::AttachToRun).to receive(:call).and_raise(StandardError, "render failed")

        expect {
          controller.send(:attach_marketplace_entries, agent_run:)
        }.to raise_error(StandardError, "render failed")
      end
    end
  end
end
