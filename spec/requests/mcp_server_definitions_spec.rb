# frozen_string_literal: true

require "rails_helper"

RSpec.describe "McpServerDefinitions" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before do
    user.add_role(:admin, account)
    create(:user_setting, user: user)
  end

  describe "GET /mcp_server_definitions" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get mcp_server_definitions_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before { sign_in user }

      it "renders the index page" do
        get mcp_server_definitions_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("MCP Server Definitions")
      end

      it "shows existing definitions" do
        mcp = create(:mcp_server_definition, account: account, name: "test-mcp")
        get mcp_server_definitions_path
        expect(response.body).to include("test-mcp")
      end

      it "shows empty state when no definitions exist" do
        get mcp_server_definitions_path
        expect(response.body).to include("No MCP server definitions")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "redirects with authorization error" do
        get mcp_server_definitions_path
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "GET /mcp_server_definitions/new" do
    context "when authenticated as admin" do
      before { sign_in user }

      it "renders the new form" do
        get new_mcp_server_definition_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("New MCP Server Definition")
      end
    end
  end

  describe "POST /mcp_server_definitions" do
    before { sign_in user }

    let(:valid_params) do
      {
        mcp_server_definition: {
          name: "my-mcp-server",
          transport: "stdio",
          install_type: "npx",
          command: "@modelcontextprotocol/server-filesystem",
          args_json: '["--workspace"]',
          env_json: '{"API_KEY": "test"}'
        }
      }
    end

    context "with valid parameters" do
      it "creates a new MCP server definition" do
        expect {
          post mcp_server_definitions_path, params: valid_params
        }.to change(McpServerDefinition, :count).by(1)
      end

      it "redirects to the show page with success message" do
        post mcp_server_definitions_path, params: valid_params
        expect(response).to redirect_to(mcp_server_definition_path(McpServerDefinition.last))
        expect(flash[:notice]).to include("successfully created")
      end

      it "stores args and env as parsed JSON" do
        post mcp_server_definitions_path, params: valid_params
        mcp = McpServerDefinition.last
        expect(mcp.args).to eq([ "--workspace" ])
        expect(mcp.env).to eq({ "API_KEY" => "test" })
      end
    end

    context "with invalid parameters" do
      it "re-renders the form when name is missing" do
        post mcp_server_definitions_path, params: { mcp_server_definition: { name: "", transport: "stdio", install_type: "npx", command: "cmd" } }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "re-renders the form when args_json is invalid JSON" do
        post mcp_server_definitions_path, params: {
          mcp_server_definition: {
            name: "test",
            transport: "stdio",
            install_type: "npx",
            command: "cmd",
            args_json: "not-json"
          }
        }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "re-renders the form when env_json is invalid JSON" do
        post mcp_server_definitions_path, params: {
          mcp_server_definition: {
            name: "test",
            transport: "stdio",
            install_type: "npx",
            command: "cmd",
            env_json: "not-json"
          }
        }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "GET /mcp_server_definitions/:id" do
    before { sign_in user }

    it "shows the definition details" do
      mcp = create(:mcp_server_definition, account: account, name: "my-mcp")
      get mcp_server_definition_path(mcp)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("my-mcp")
    end
  end

  describe "GET /mcp_server_definitions/:id/edit" do
    before { sign_in user }

    it "shows the edit form" do
      mcp = create(:mcp_server_definition, account: account, name: "my-mcp")
      get edit_mcp_server_definition_path(mcp)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Edit MCP Server Definition")
      expect(response.body).to include("my-mcp")
    end
  end

  describe "PATCH /mcp_server_definitions/:id" do
    before { sign_in user }

    it "updates the definition" do
      mcp = create(:mcp_server_definition, account: account, name: "old-name")
      patch mcp_server_definition_path(mcp), params: { mcp_server_definition: { name: "new-name" } }
      expect(mcp.reload.name).to eq("new-name")
      expect(response).to redirect_to(mcp_server_definition_path(mcp))
      expect(flash[:notice]).to include("successfully updated")
    end

    it "re-renders the form on validation error" do
      mcp = create(:mcp_server_definition, account: account)
      patch mcp_server_definition_path(mcp), params: { mcp_server_definition: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /mcp_server_definitions/:id" do
    context "when user is owner" do
      before do
        user.add_role(:owner, account)
        sign_in user
      end

      it "deletes the definition" do
        mcp = create(:mcp_server_definition, account: account)
        expect {
          delete mcp_server_definition_path(mcp)
        }.to change(McpServerDefinition, :count).by(-1)
      end

      it "redirects with success message" do
        mcp = create(:mcp_server_definition, account: account)
        delete mcp_server_definition_path(mcp)
        expect(response).to redirect_to(mcp_server_definitions_path)
        expect(flash[:notice]).to include("successfully deleted")
      end
    end

    context "when user is admin (not owner)" do
      let(:admin_only_user) { create(:user, :admin, account: account) }

      before { create(:user_setting, user: admin_only_user) }

      it "does not allow deletion" do
        mcp = create(:mcp_server_definition, account: account)
        sign_in admin_only_user
        delete mcp_server_definition_path(mcp)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end
end
