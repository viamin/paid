# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Project interoperability" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner_user) }

  before { sign_in owner_user }

  describe "PATCH /projects/:project_id/interop_settings" do
    it "updates the project adoption mode and enabled sources" do
      patch project_interop_settings_path(project), params: {
        project: {
          adoption_mode: "review_only",
          external_execution_sources: { cursor: true }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(project.reload.adoption_mode).to eq("review_only")
      expect(project.external_execution_enabled_for?(:cursor)).to be(true)
    end
  end

  describe "POST /projects/:project_id/external_agent_runs" do
    before do
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "external_execution_sources" => { "cursor" => true }
      })
    end

    it "ingests an external execution into agent_runs" do
      expect {
        post project_external_agent_runs_path(project), params: {
          external_agent_run: {
            external_source_key: "cursor",
            external_run_key: "cursor-run-42",
            custom_prompt: "Imported run",
            status: "completed"
          }
        }
      }.to change(project.agent_runs, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(project.agent_runs.last.execution_origin).to eq("external")
    end
  end

  describe "POST /projects/:project_id/interoperability_imports" do
    it "imports migration payloads into project-scoped configuration records" do
      post project_interoperability_imports_path(project), params: {
        interoperability_import: {
          source_system: "github_copilot",
          prompts: [
            {
              slug: "copilot.prompt",
              name: "Copilot Prompt",
              category: "coding",
              template: "Ship it"
            }
          ]
        }
      }

      expect(response).to have_http_status(:created)
      expect(project.prompts.find_by!(slug: "copilot.prompt")).to be_present
    end
  end
end
