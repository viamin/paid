# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::BaseTool do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let!(:project) { create(:project, account: account) }

  before do
    stub_const("Tools::BaseToolAuthorizedSpecTool", Class.new(described_class) do
      authorize :show?, ->(args) { Project.find(args.fetch(:project_id)) }

      def self.tool_name = "base_tool_authorized_spec"
      def self.description = "Authorized base tool spec"

      def perform(project_id:)
        {
          current_account_id: Current.account&.id,
          bypass_enabled: TenantContext.bypass_enabled?,
          authorization_performed: instance_variable_get(:@preflight_authorization_performed),
          project_id: Project.find(project_id).id
        }
      end
    end)

    stub_const("Tools::BaseToolUnauthorizedSpecTool", Class.new(described_class) do
      attr_reader :perform_called

      def self.tool_name = "base_tool_unauthorized_spec"
      def self.description = "Unauthorized base tool spec"

      def perform
        @perform_called = true
        { ok: true }
      end
    end)

    stub_const("Tools::BaseToolPostHocAuthorizedSpecTool", Class.new(described_class) do
      attr_reader :perform_called

      def self.tool_name = "base_tool_post_hoc_authorized_spec"
      def self.description = "Post hoc authorization base tool spec"

      def perform(project_id:)
        @perform_called = true
        authorize(Project.find(project_id), :show?)
        { ok: true }
      end
    end)
  end

  describe "#dispatch" do
    it "requires an authenticated user" do
      tool = Tools::BaseToolAuthorizedSpecTool.new(user: nil, session: nil)

      expect { tool.dispatch(project_id: project.id) }
        .to raise_error(Tools::UnauthorizedError, "Tool calls require an authenticated user")
    end

    it "runs the tool inside the user's tenant context and authorizes before the body" do
      tool = Tools::BaseToolAuthorizedSpecTool.new(user: user, session: session)
      other_account = create(:account)

      result = nil
      restored_account = TenantContext.with(other_account) do
        result = tool.dispatch(project_id: project.id)
        Current.account
      end

      expect(result).to include(
        current_account_id: account.id,
        bypass_enabled: false,
        authorization_performed: true,
        project_id: project.id
      )
      expect(restored_account).to eq(other_account)
    end

    it "raises when the tool body never performs authorization" do
      tool = Tools::BaseToolUnauthorizedSpecTool.new(user: user, session: session)

      expect { tool.dispatch }
        .to raise_error(Tools::UnauthorizedError, "base_tool_unauthorized_spec must authorize before execution")
      expect(tool.perform_called).to be_nil
    end

    it "raises before entering perform when authorization only happens post hoc" do
      tool = Tools::BaseToolPostHocAuthorizedSpecTool.new(user: user, session: session)

      expect { tool.dispatch(project_id: project.id) }
        .to raise_error(Tools::UnauthorizedError, "base_tool_post_hoc_authorized_spec must authorize before execution")
      expect(tool.perform_called).to be_nil
    end
  end
end
