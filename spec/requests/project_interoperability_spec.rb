# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Project interoperability" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner_user) }

  describe "PATCH /projects/:project_id/interop_settings" do
    before { sign_in owner_user }

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

  describe "POST /api/projects/:project_id/external_agent_runs" do
    let!(:cursor_credential) do
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: "cursor",
        auth_kind: "api_key",
        secret: "cursor-shared-secret"
      )
    end
    let(:external_run_headers) { { "Authorization" => "Bearer #{cursor_credential.secret}" } }

    before do
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "external_execution_sources" => { "cursor" => true }
      })
    end

    it "ingests an external execution into agent_runs" do
      expect {
        post api_project_external_agent_runs_path(project), params: {
          external_agent_run: {
            external_source_key: "cursor",
            external_run_key: "cursor-run-42",
            custom_prompt: "Imported run",
            status: "completed"
          }
        }, headers: external_run_headers
      }.to change(project.agent_runs, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(project.agent_runs.last.execution_origin).to eq("external")
    end

    it "returns 404 when the referenced issue is not part of the project" do
      other_project = create(:project, account: account, created_by: owner_user)
      other_issue = create(:issue, project: other_project)

      post api_project_external_agent_runs_path(project), params: {
        external_agent_run: {
          external_source_key: "cursor",
          external_run_key: "cursor-run-missing-issue",
          issue_id: other_issue.id,
          custom_prompt: "Imported run",
          status: "completed"
        }
      }, headers: external_run_headers

      expect(response).to have_http_status(:not_found)
    end

    it "blocks external run ingestion in observe_only mode" do
      project.update!(interop_settings: {
        "adoption_mode" => "observe_only",
        "external_execution_sources" => { "cursor" => true }
      })

      expect {
        post api_project_external_agent_runs_path(project), params: {
          external_agent_run: {
            external_source_key: "cursor",
            external_run_key: "cursor-run-blocked",
            custom_prompt: "Imported run",
            status: "completed"
          }
        }, headers: external_run_headers
      }.not_to change(project.agent_runs, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").first).to match(/ingest_external_runs is not permitted/)
    end

    it "rejects requests without a valid integration credential" do
      expect {
        post api_project_external_agent_runs_path(project), params: {
          external_agent_run: {
            external_source_key: "cursor",
            external_run_key: "cursor-run-unauthorized",
            custom_prompt: "Imported run",
            status: "completed"
          }
        }
      }.not_to change(project.agent_runs, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.fetch("errors")).to include("Invalid integration credential")
    end

    it "accepts older active external-run credentials during rotation" do
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: "cursor",
        auth_kind: "api_key",
        secret: "cursor-new-secret"
      )

      expect {
        post api_project_external_agent_runs_path(project), params: {
          external_agent_run: {
            external_source_key: "cursor",
            external_run_key: "cursor-run-rotated-secret",
            custom_prompt: "Imported run",
            status: "completed"
          }
        }, headers: external_run_headers
      }.to change(project.agent_runs, :count).by(1)

      expect(response).to have_http_status(:created)
    end
  end

  describe "POST /projects/:project_id/interoperability_imports" do
    before do
      sign_in owner_user
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

  describe "POST /api/projects/:project_id/connector_events" do
    let(:slack_secret) { "signing-secret" }
    let(:slack_timestamp) { Time.current.to_i.to_s }
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
    let(:connector_event_json) { connector_event_params.to_json }
    let(:slack_signature) do
      digest = OpenSSL::HMAC.hexdigest("SHA256", slack_secret, "v0:#{slack_timestamp}:#{connector_event_json}")
      "v0=#{digest}"
    end
    let(:signed_slack_headers) do
      {
        "CONTENT_TYPE" => "application/json",
        "X-Slack-Request-Timestamp" => slack_timestamp,
        "X-Slack-Signature" => slack_signature
      }
    end

    before do
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "connectors" => { "slack" => true }
      })
    end

    it "blocks connector event ingestion in observe_only mode" do
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: "slack",
        auth_kind: "api_key",
        secret: slack_secret
      )

      project.update!(interop_settings: {
        "adoption_mode" => "observe_only",
        "connectors" => { "slack" => true }
      })

      expect {
        post api_project_connector_events_path(project), params: connector_event_params.to_json, headers: signed_slack_headers
      }.not_to change(project.external_connector_events, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").first).to match(/receive_connector_events is not permitted/)
    end

    it "verifies Slack signatures from request headers without requiring a body field" do
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: "slack",
        auth_kind: "api_key",
        secret: slack_secret
      )

      expect {
        post api_project_connector_events_path(project), params: connector_event_json, headers: signed_slack_headers
      }.to change(project.external_connector_events, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it "accepts connector requests signed with an older active credential during rotation" do
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: "slack",
        auth_kind: "api_key",
        secret: slack_secret
      )
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: "slack",
        auth_kind: "api_key",
        secret: "new-signing-secret"
      )

      expect {
        post api_project_connector_events_path(project), params: connector_event_json, headers: signed_slack_headers
      }.to change(project.external_connector_events, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it "rejects unsigned Slack requests when a signing credential is configured" do
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: "slack",
        auth_kind: "api_key",
        secret: slack_secret
      )

      expect {
        post api_project_connector_events_path(project), params: connector_event_json, headers: {
          "CONTENT_TYPE" => "application/json",
          "X-Slack-Request-Timestamp" => slack_timestamp
        }
      }.not_to change(project.external_connector_events, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").first).to match(/signature is required for slack/)
    end

    it "rejects stale Slack signatures" do
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: "slack",
        auth_kind: "api_key",
        secret: slack_secret
      )

      stale_timestamp = 10.minutes.ago.to_i.to_s
      stale_signature = "v0=#{OpenSSL::HMAC.hexdigest("SHA256", slack_secret, "v0:#{stale_timestamp}:#{connector_event_json}")}"

      expect {
        post api_project_connector_events_path(project), params: connector_event_json, headers: {
          "CONTENT_TYPE" => "application/json",
          "X-Slack-Request-Timestamp" => stale_timestamp,
          "X-Slack-Signature" => stale_signature
        }
      }.not_to change(project.external_connector_events, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").first).to match(/signature verification failed for slack/)
    end

    it "accepts GitLab secret-token headers" do
      create_connector_credential!("gitlab", gitlab_secret)
      enable_connector!("gitlab")

      expect {
        post api_project_connector_events_path(project), params: gitlab_event_body("gitlab-token-event", 42, "MR title"), headers: {
          "CONTENT_TYPE" => "application/json",
          "X-Gitlab-Token" => gitlab_secret
        }
      }.to change(project.external_connector_events, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it "accepts GitLab signing-token headers" do
      webhook_id = SecureRandom.uuid
      webhook_timestamp = Time.current.to_i.to_s
      gitlab_body = gitlab_event_body("gitlab-signed-event", 84, "Signed MR")
      create_connector_credential!("gitlab", gitlab_signing_secret)
      enable_connector!("gitlab")

      gitlab_digest = OpenSSL::HMAC.digest("SHA256", gitlab_signing_key, "#{webhook_id}.#{webhook_timestamp}.#{gitlab_body}")
      gitlab_signature = "v1,#{Base64.strict_encode64(gitlab_digest)}"

      expect {
        post api_project_connector_events_path(project), params: gitlab_body, headers: {
          "CONTENT_TYPE" => "application/json",
          "webhook-id" => webhook_id,
          "webhook-timestamp" => webhook_timestamp,
          "webhook-signature" => gitlab_signature
        }
      }.to change(project.external_connector_events, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it "rejects connector requests when no active integration credential is configured" do
      expect {
        post api_project_connector_events_path(project), params: connector_event_json, headers: signed_slack_headers
      }.not_to change(project.external_connector_events, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.fetch("errors").first).to match(/No active integration credential configured/)
    end

    it "accepts ci_systems credentials for CI connector events" do
      ci_secret = "ci-shared-secret"
      create_connector_credential!("ci_systems", ci_secret)
      enable_connector!("ci_systems")
      payload = ci_systems_event_body("ci-event-1")
      signature = ci_systems_signature(payload, ci_secret)

      expect {
        post api_project_connector_events_path(project), params: payload, headers: {
          "CONTENT_TYPE" => "application/json",
          "X-Signature" => signature
        }
      }.to change(project.external_connector_events, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    def create_connector_credential!(service_key, secret)
      create(
        :integration_credential,
        account: account,
        created_by: owner_user,
        service_key: service_key,
        auth_kind: "api_key",
        secret: secret
      )
    end

    def enable_connector!(connector_key)
      project.update!(interop_settings: {
        "adoption_mode" => "advisory",
        "connectors" => { connector_key => true }
      })
    end

    def gitlab_event_body(external_event_id, iid, title)
      {
        connector_event: {
          connector_key: "gitlab",
          event_type: "merge_request_opened",
          external_event_id: external_event_id,
          payload: {
            object_attributes: {
              iid: iid,
              title: title,
              state: "opened"
            }
          }
        }
      }.to_json
    end

    def ci_systems_event_body(external_event_id)
      {
        connector_event: {
          connector_key: "ci_systems",
          event_type: "pipeline_completed",
          external_event_id: external_event_id,
          payload: {
            run: {
              id: 42,
              status: "success"
            }
          }
        }
      }.to_json
    end

    def ci_systems_signature(payload, secret)
      OpenSSL::HMAC.hexdigest("SHA256", secret, payload)
    end

    def gitlab_secret
      "gitlab-secret"
    end

    def gitlab_signing_key
      "gitlab-signing-secret"
    end

    def gitlab_signing_secret
      "whsec_#{Base64.strict_encode64(gitlab_signing_key)}"
    end
  end
end
