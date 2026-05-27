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
      expect(response.parsed_body.dig("interop_settings", "adoption_mode")).to eq("review_only")
      expect(response.parsed_body.dig("interop_settings", "external_execution_sources", "cursor")).to be(true)
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

    it "returns 404 when the referenced issue is not part of the project" do
      other_project = create(:project, account: account, created_by: owner_user)
      other_issue = create(:issue, project: other_project)

      post project_external_agent_runs_path(project), params: {
        external_agent_run: {
          external_source_key: "cursor",
          external_run_key: "cursor-run-missing-issue",
          issue_id: other_issue.id,
          custom_prompt: "Imported run",
          status: "completed"
        }
      }

      expect(response).to have_http_status(:not_found)
    end

    it "blocks external run ingestion in observe_only mode" do
      project.update!(interop_settings: {
        "adoption_mode" => "observe_only",
        "external_execution_sources" => { "cursor" => true }
      })

      expect {
        post project_external_agent_runs_path(project), params: {
          external_agent_run: {
            external_source_key: "cursor",
            external_run_key: "cursor-run-blocked",
            custom_prompt: "Imported run",
            status: "completed"
          }
        }
      }.not_to change(project.agent_runs, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").first).to match(/ingest_external_runs is not permitted/)
    end
  end

  describe "POST /projects/:project_id/interoperability_imports" do
    before do
      project.update!(interop_settings: { "adoption_mode" => "advisory" })
    end

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

    it "blocks imports in observe_only mode" do
      project.update!(interop_settings: { "adoption_mode" => "observe_only" })

      post project_interoperability_imports_path(project), params: {
        interoperability_import: {
          source_system: "github_copilot",
          prompts: [
            {
              slug: "copilot.blocked",
              name: "Blocked Prompt",
              category: "coding",
              template: "Ship it"
            }
          ]
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").first).to match(/import_config is not permitted/)
      expect(project.prompts.find_by(slug: "copilot.blocked")).to be_nil
    end
  end

  describe "POST /projects/:project_id/connector_events" do
    let(:connector_event_params) do
      {
        connector_event: {
          connector_key: "slack",
          event_type: "message_posted",
          external_event_id: "slack-event-blocked",
          payload: {
            event: {
              ts: "123.456",
              type: "message",
              text: "hello"
            }
          }
        }
      }
    end

    before do
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "connectors" => { "slack" => true }
      })
    end

    it "blocks connector event ingestion in observe_only mode" do
      project.update!(interop_settings: {
        "adoption_mode" => "observe_only",
        "connectors" => { "slack" => true }
      })

      expect {
        post project_connector_events_path(project), params: connector_event_params
      }.not_to change(project.external_connector_events, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").first).to match(/receive_connector_events is not permitted/)
    end
  end
end
