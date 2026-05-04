# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::McpServers" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "POST /projects/:project_id/project_mcp_servers" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        mcp = create(:mcp_server_definition, account: account)
        post project_project_mcp_servers_path(project), params: { mcp_server_definition_id: mcp.id }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "associates an MCP server with the project" do
        mcp = create(:mcp_server_definition, account: account)
        expect {
          post project_project_mcp_servers_path(project), params: { mcp_server_definition_id: mcp.id }
        }.to change(ProjectMcpServer, :count).by(1)
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to include("added")
      end

      it "does not create duplicate associations" do
        mcp = create(:mcp_server_definition, account: account)
        create(:project_mcp_server, project: project, mcp_server_definition: mcp)
        expect {
          post project_project_mcp_servers_path(project), params: { mcp_server_definition_id: mcp.id }
        }.not_to change(ProjectMcpServer, :count)
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:alert]).to include("already associated")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before { sign_in member }

      it "redirects with authorization error" do
        mcp = create(:mcp_server_definition, account: account)
        post project_project_mcp_servers_path(project), params: { mcp_server_definition_id: mcp.id }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "redirects with authorization error" do
        mcp = create(:mcp_server_definition, account: account)
        post project_project_mcp_servers_path(project), params: { mcp_server_definition_id: mcp.id }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "DELETE /projects/:project_id/project_mcp_servers/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        mcp = create(:mcp_server_definition, account: account)
        pms = create(:project_mcp_server, project: project, mcp_server_definition: mcp)
        delete project_project_mcp_server_path(project, pms)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "removes the MCP server from the project" do
        mcp = create(:mcp_server_definition, account: account)
        pms = create(:project_mcp_server, project: project, mcp_server_definition: mcp)
        expect {
          delete project_project_mcp_server_path(project, pms)
        }.to change(ProjectMcpServer, :count).by(-1)
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to include("removed")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before { sign_in member }

      it "redirects with authorization error" do
        mcp = create(:mcp_server_definition, account: account)
        pms = create(:project_mcp_server, project: project, mcp_server_definition: mcp)
        delete project_project_mcp_server_path(project, pms)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "redirects with authorization error" do
        mcp = create(:mcp_server_definition, account: account)
        pms = create(:project_mcp_server, project: project, mcp_server_definition: mcp)
        delete project_project_mcp_server_path(project, pms)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end
end
