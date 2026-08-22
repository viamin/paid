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

  describe "#marketplace_auto_attach_enabled_for_current_user?" do
    let(:controller) { described_class.new }

    it "returns false when the current user has no settings object" do
      allow(controller).to receive(:current_user).and_return(double(settings: nil))

      expect(controller.send(:marketplace_auto_attach_enabled_for_current_user?)).to be(false)
    end
  end

  describe "#marketplace_auto_attach_required_for_current_account?" do
    let(:controller) { described_class.new }

    it "uses the project account and returns false when that account has no tenant settings" do
      project_account = double(tenant_setting: nil)
      controller.instance_variable_set(:@project, double(account: project_account))

      expect(controller.send(:marketplace_auto_attach_required_for_current_account?)).to be(false)
    end
  end

  describe "#marketplace_entries_for_new_run" do
    let(:controller) { described_class.new }
    let(:account_class) { Struct.new(:marketplace_entries) }
    let(:association_class) do
      Class.new do
        def active; end
      end
    end
    let(:active_scope_class) do
      Class.new do
        def where; end
      end
    end
    let(:where_chain_class) do
      Class.new do
        def not(*) = nil
      end
    end
    let(:filtered_scope_class) do
      Class.new do
        def ordered; end
      end
    end
    let(:ordered_scope_class) do
      Class.new do
        def includes(*) = nil
      end
    end

    it "only returns active entries with a current immutable version" do
      association = instance_double(association_class)
      active_scope = instance_double(active_scope_class)
      where_chain = instance_double(where_chain_class)
      filtered_scope = instance_double(filtered_scope_class)
      ordered_scope = instance_double(ordered_scope_class)
      result_scope = Object.new
      account = instance_double(account_class, marketplace_entries: association)
      project = double(account: account)

      controller.instance_variable_set(:@project, project)
      allow(association).to receive(:active).and_return(active_scope)
      allow(active_scope).to receive(:where).and_return(where_chain)
      allow(where_chain).to receive(:not).with(current_version_id: nil).and_return(filtered_scope)
      allow(filtered_scope).to receive(:ordered).and_return(ordered_scope)
      allow(ordered_scope).to receive(:includes).with(:current_version).and_return(result_scope)

      expect(controller.send(:marketplace_entries_for_new_run)).to eq(result_scope)
    end

    it "does not rely on the ambient current_account" do
      association = instance_double(association_class)
      active_scope = instance_double(active_scope_class)
      where_chain = instance_double(where_chain_class)
      filtered_scope = instance_double(filtered_scope_class)
      ordered_scope = instance_double(ordered_scope_class)
      result_scope = Object.new
      project_account = instance_double(account_class, marketplace_entries: association)

      controller.instance_variable_set(:@project, double(account: project_account))
      allow(controller).to receive(:current_account).and_raise("should not use current_account")
      allow(association).to receive(:active).and_return(active_scope)
      allow(active_scope).to receive(:where).and_return(where_chain)
      allow(where_chain).to receive(:not).with(current_version_id: nil).and_return(filtered_scope)
      allow(filtered_scope).to receive(:ordered).and_return(ordered_scope)
      allow(ordered_scope).to receive(:includes).with(:current_version).and_return(result_scope)

      expect(controller.send(:marketplace_entries_for_new_run)).to eq(result_scope)
    end
  end

  describe "#docker_host_selection_context" do
    let(:controller) { described_class.new }
    let(:host) { instance_double(DockerHost) }
    let(:runner) { instance_double(Runner, subscription?: true, id: 42, requires_direct_outbound?: false) }
    let(:eligible_hosts_scope) { [ host ] }
    let(:placement_ready_scope) { double(ordered: eligible_hosts_scope) }
    let(:auth_source) { instance_double(Runners::SubscriptionAuthEligibility::AuthSource, managed?: false, host_forwarded?: false) }
    let(:docker_hosts) { double(placement_ready_for_restricted_agent_runs: placement_ready_scope) }
    let(:account) { instance_double(Account, docker_hosts:) }

    before do
      allow(controller).to receive_messages(
        current_account: account
      )
      allow(controller).to receive(:subscription_auth_source_for).with(runner).and_return(auth_source)
      allow(controller).to receive(:docker_host_eligible_for_manual_selection?).with(host, auth_source: auth_source).and_return(true)
    end

    it "memoizes the auth source and eligible hosts per runner" do
      first_context = controller.send(:docker_host_selection_context, runner: runner)
      second_context = controller.send(:docker_host_selection_context, runner: runner)

      expect(first_context).to equal(second_context)
      expect(first_context[:auth_source]).to eq(auth_source)
      expect(first_context[:eligible_hosts]).to eq([ host ])
      expect(controller).to have_received(:subscription_auth_source_for).once
    end

    it "uses the resolved runner instead of re-reading params when checking unrestricted placement" do
      unrestricted_scope = double(ordered: eligible_hosts_scope)
      direct_outbound_runner = instance_double(Runner, subscription?: false, id: 99, requires_direct_outbound?: true)
      docker_hosts = double(
        placement_ready_for_agent_runs: unrestricted_scope,
        placement_ready_for_restricted_agent_runs: placement_ready_scope
      )

      allow(controller).to receive(:current_account).and_return(instance_double(Account, docker_hosts:))
      allow(controller).to receive(:runner_for_docker_host_param).and_raise("should not re-read params")
      allow(controller).to receive(:docker_host_eligible_for_manual_selection?).with(host, auth_source: nil).and_return(true)
      expect(docker_hosts).to receive(:placement_ready_for_agent_runs).and_return(unrestricted_scope)
      expect(docker_hosts).not_to receive(:placement_ready_for_restricted_agent_runs)

      context = controller.send(:docker_host_selection_context, runner: direct_outbound_runner)

      expect(context[:auth_source]).to be_nil
      expect(context[:eligible_hosts]).to eq([ host ])
    end
  end
end
