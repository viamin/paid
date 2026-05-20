# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::RunnerResolver do
  describe ".call" do
    it "honors tenant API keys owned by another account member" do
      account = create(:account)
      owner = create(:user, :owner, account: account)
      member = create(:user, :member, account: account)
      project = create(:project, account: account, created_by: owner)
      api_key = create(:provider_api_key, user: member, api_service_type: "anthropic")
      create(:tenant_setting, account: account,
        runner_preferences: { "api_key_ids" => { "anthropic" => api_key.id } })

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")
      runner = Runner.find(runner_id)

      expect(agent_type).to eq("claude_code")
      expect(runner).to have_attributes(
        user: owner,
        runner_key: "claude",
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    it "uses the project-level preferred_agent_type from model_preferences" do
      project = create(:project)
      owner = project.created_by
      cursor_runner = create(:runner, user: owner, runner_key: "cursor")
      project.update!(model_preferences: project.model_preferences.merge("preferred_agent_type" => "cursor"))

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")

      expect(agent_type).to eq("cursor")
      expect(runner_id).to eq(cursor_runner.id)
    end

    it "prefers requested_agent_type over project-level preferred_agent_type" do
      project = create(:project)
      owner = project.created_by
      create(:runner, user: owner, runner_key: "cursor")
      create(:runner, user: owner, runner_key: "codex")
      project.update!(model_preferences: project.model_preferences.merge("preferred_agent_type" => "cursor"))

      _runner_id, agent_type = described_class.call(
        project: project,
        goal: "create_pr",
        requested_agent_type: "codex"
      )

      expect(agent_type).to eq("codex")
    end

    it "ignores requested runner ids from another account" do
      project = create(:project)
      other_owner = create(:user, :owner)
      other_runner = create(:runner, user: other_owner, runner_key: "codex")

      runner_id, agent_type = described_class.call(
        project: project,
        goal: "create_pr",
        requested_runner_id: other_runner.id
      )

      expect(runner_id).not_to eq(other_runner.id)
      expect(Runner.find(runner_id)).to eq(project.created_by.runners.find_by!(runner_key: "claude"))
      expect(agent_type).to eq("claude_code")
    end

    it "falls back to the first enabled runnable runner when the saved setting points to a disabled runner" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])

      project = create(:project)
      owner = project.created_by
      cursor_runner = create(:runner, user: owner, runner_key: "cursor")
      owner.settings.update!(default_agent_runner: "cursor")
      cursor_runner.update!(enabled_for_agent_runs: false)

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")

      expect(runner_id).to eq(owner.runners.find_by!(runner_key: "claude").id)
      expect(agent_type).to eq("claude_code")
    end

    it "prefers the automated runnable runner family for tenant API-key selection" do
      project = create(:project)
      owner, settings = project.created_by, project.created_by.settings
      cursor_runner = create(:runner, user: owner, runner_key: "cursor")
      codex_runner = create(:runner, user: owner, runner_key: "codex")
      owner.settings.update!(default_agent_runner: "cursor", runner_selection_mode: "round_robin")
      allow(AgentRuns::UserSettingsResolver).to receive(:call).with(project: project, strict: false).and_return(settings)
      allow(settings).to receive(:select_automated_runner_identifier).with(goal: "create_pr").and_return(codex_runner.routing_key)

      api_key = create(:provider_api_key, user: owner, api_service_type: "openai")
      create(:tenant_setting, account: project.account,
        runner_preferences: { "api_key_ids" => { "openai" => api_key.id } })

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")
      runner = Runner.find(runner_id)

      expect(agent_type).to eq("codex")
      expect(runner).to have_attributes(
        user: owner,
        runner_key: "codex",
        auth_type: "api_key",
        provider_api_key: api_key
      )
      expect(runner_id).not_to eq(cursor_runner.id)
    end

    it "keeps the configured runner family for tenant API-key selection when the automated runner is stale" do
      project = create(:project)
      owner = project.created_by
      settings = owner.settings
      cursor_runner = create(:runner, user: owner, runner_key: "cursor")
      owner.settings.update!(default_agent_runner: "cursor")
      cursor_runner.update!(enabled_for_agent_runs: false)
      allow(AgentRuns::UserSettingsResolver).to receive(:call).with(project: project, strict: false).and_return(settings)
      allow(settings).to receive(:select_automated_runner_identifier).with(goal: "create_pr").and_return(cursor_runner.routing_key)

      api_key = create(:provider_api_key, user: owner, api_service_type: "anthropic")
      create(:tenant_setting, account: project.account,
        runner_preferences: { "api_key_ids" => { "anthropic" => api_key.id } })

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")
      runner = Runner.find(runner_id)

      expect(agent_type).to eq("cursor")
      expect(runner).to have_attributes(
        user: owner,
        runner_key: "cursor",
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    it "does not create a tenant API-key runner for a non-runnable configured runner key" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude])
      allow(RunnerSupport).to receive(:container_executable_runner_key?) do |key|
        key == "claude"
      end

      project = create(:project)
      owner = project.created_by
      stale_runner = create(:runner, user: owner, runner_key: "cursor", enabled_for_agent_runs: true)
      owner.settings.update!(default_agent_runner: "cursor")

      api_key = create(:provider_api_key, user: owner, api_service_type: "anthropic")
      create(:tenant_setting, account: project.account,
        runner_preferences: { "api_key_ids" => { "anthropic" => api_key.id } })

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")

      expect(runner_id).not_to eq(stale_runner.id)
      resolved_runner = Runner.find(runner_id)
      expect(resolved_runner.runner_key).to eq("claude")
      expect(agent_type).to eq("claude_code")
    end

    it "uses the runner's required API service type for dynamic aider tenant API-key selection" do
      project = create(:project)
      owner = project.created_by
      aider_runner = create(:runner, user: owner, runner_key: "aider", auth_type: "subscription",
        config: { "aider" => { "api_provider" => "zai", "model" => "glm-5.1" } })
      owner.settings.update!(default_agent_runner: aider_runner.routing_key)

      api_key = create(:provider_api_key, user: owner, api_service_type: "zai")
      create(:tenant_setting, account: project.account,
        runner_preferences: { "api_key_ids" => { "zai" => api_key.id } })

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")
      runner = Runner.find(runner_id)

      expect(agent_type).to eq("aider")
      expect(runner).to have_attributes(
        user: owner,
        runner_key: "aider",
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    it "falls back to an account integration credential when no tenant API key is selected" do
      account = create(:account)
      owner = create(:user, :owner, account: account)
      project = create(:project, account: account, created_by: owner)
      credential = create(:integration_credential, account: account, created_by: owner, service_key: "claude")

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")
      runner = Runner.find(runner_id)

      expect(agent_type).to eq("claude_code")
      expect(runner).to have_attributes(
        user: owner,
        runner_key: "claude",
        auth_type: "api_key",
        provider_api_key: nil,
        integration_credential: credential
      )
    end

    it "prefers the tenant-selected ProviderApiKey over an account integration credential" do
      account = create(:account)
      owner = create(:user, :owner, account: account)
      project = create(:project, account: account, created_by: owner)
      api_key = create(:provider_api_key, user: owner, api_service_type: "anthropic")
      create(:integration_credential, account: account, created_by: owner, service_key: "claude")
      create(:tenant_setting, account: account,
        runner_preferences: { "api_key_ids" => { "anthropic" => api_key.id } })

      runner_id, = described_class.call(project: project, goal: "create_pr")
      runner = Runner.find(runner_id)

      expect(runner.provider_api_key).to eq(api_key)
      expect(runner.integration_credential).to be_nil
    end

    it "ignores revoked and expired integration credentials" do
      account = create(:account)
      owner = create(:user, :owner, account: account)
      project = create(:project, account: account, created_by: owner)
      create(:integration_credential, :revoked, account: account, created_by: owner, service_key: "claude")
      create(:integration_credential, :expired, account: account, created_by: owner, service_key: "claude")

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")
      runner = Runner.find(runner_id)

      expect(agent_type).to eq("claude_code")
      expect(runner.auth_type).to eq("subscription")
      expect(runner.integration_credential).to be_nil
    end

    it "does not use integration credentials from another account" do
      project = create(:project)
      other_account = create(:account)
      other_owner = create(:user, :owner, account: other_account)
      create(:integration_credential, account: other_account, created_by: other_owner, service_key: "claude")

      runner_id, agent_type = described_class.call(project: project, goal: "create_pr")
      runner = Runner.find(runner_id)

      expect(agent_type).to eq("claude_code")
      expect(runner.auth_type).to eq("subscription")
      expect(runner.integration_credential).to be_nil
    end

    it "falls back to a nil runner id with the first runnable agent type when no owner runners are available" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[codex])

      project = build_stubbed(:project)
      allow(project).to receive(:effective_owner).and_return(nil)

      runner_id, agent_type = described_class.new(project: project, goal: "create_pr").send(:fallback_from_settings)

      expect(runner_id).to be_nil
      expect(agent_type).to eq("codex")
    end
  end
end
