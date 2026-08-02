# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:pull_request) { create(:issue, :pull_request, project: project) }
  let(:agent_run) { create(:agent_run, :running, project: project, issue: issue) }
  let(:other_account) { create(:account) }

  let(:scenarios) do
    [
      {
        tool_name: "list_projects",
        denied_user: -> { nil },
        arguments: -> { {} },
        ui_call: ->(user) { Pundit.policy_scope!(user, Project).order(updated_at: :desc).limit(20).to_a }
      },
      {
        tool_name: "list_agent_runs",
        denied_user: -> { nil },
        arguments: -> { {} },
        ui_call: ->(user) { Pundit.policy_scope!(user, AgentRun).recent.limit(20).to_a }
      },
      {
        tool_name: "list_configuration_profiles",
        denied_user: -> { nil },
        arguments: -> { {} },
        ui_call: ->(user) {
          raise Tools::UnauthorizedError, "Tool calls require an authenticated user" if user.blank?

          Configuration::Profiles::Registry.summaries
        }
      },
      {
        tool_name: "plan_configuration_profile",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { profile_id: "observe_only", project_id: project.id } },
        ui_call: ->(user) {
          Pundit.policy_scope!(user, Project).find(project.id)
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          Configuration::Profiles::Planner.call(
            profile: Configuration::Profiles::Registry.fetch("observe_only"),
            project: project_record
          )
        }
      },
      {
        tool_name: "apply_configuration_profile",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { profile_id: "observe_only", project_id: project.id, confirmed: true } },
        ui_call: ->(user) {
          Pundit.policy_scope!(user, Project).find(project.id)
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          profile = Configuration::Profiles::Registry.fetch("observe_only")
          plan = Configuration::Profiles::Planner.call(profile:, project: project_record)
          Configuration::Profiles::Applier.call(plan:, project: project_record, actor: user)
        }
      },
      {
        tool_name: "get_project",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
        }
      },
      {
        tool_name: "get_project_issues",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
          project_record.issues.issues_only.order(updated_at: :desc).limit(20).to_a
        }
      },
      {
        tool_name: "get_project_pull_requests",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
          project_record.issues.pull_requests_only.order(updated_at: :desc).limit(20).to_a
        }
      },
      {
        tool_name: "update_project_settings",
        denied_user: -> { create(:user, :member, account: account) },
        arguments: -> { { project_id: project.id, settings: { paused: true }, confirmed: true } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :update?, policy_class: ProjectPolicy)
          project_record.update!(paused: true)
        }
      },
      {
        tool_name: "trigger_agent_run",
        denied_user: -> {
          project
          create(:user, :viewer, account: account)
        },
        arguments: -> { { project_id: project.id, issue_id: issue.id, confirmed: true } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :run_agent?, policy_class: ProjectPolicy)
          project_record.issues.find(issue.id)
        }
      },
      {
        tool_name: "get_agent_run",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { agent_run_id: agent_run.id } },
        ui_call: ->(user) {
          run_record = Pundit.policy_scope!(user, AgentRun).find(agent_run.id)
          authorize_record!(user, run_record, :show?)
        }
      },
      {
        tool_name: "cancel_agent_run",
        denied_user: -> {
          project
          create(:user, :viewer, account: account)
        },
        arguments: -> { { agent_run_id: agent_run.id, confirmed: true } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          run_record = project_record.agent_runs.find(agent_run.id)
          authorize_record!(user, run_record, :cancel?)
        }
      },
      {
        tool_name: "record_change_intent",
        denied_user: -> {
          project
          create(:user, :viewer, account: account)
        },
        arguments: -> { { title: "Denied", intent: "Denied", constraints: "Denied" } },
        session: ->(user) { build(:chat_session, account: user.account, created_by: user, project: project) },
        ui_call: ->(user) {
          record = project.change_intents.build(
            chat_session: build(:chat_session, account: user.account, created_by: user, project: project),
            title: "Denied",
            intent: "Denied",
            constraints: "Denied"
          )
          authorize_record!(user, record, :create?, policy_class: ChangeIntentPolicy)
        }
      },
      {
        tool_name: "get_issue_details",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id, issue_id: issue.id } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
          project_record.issues.find(issue.id)
        }
      },
      {
        tool_name: "get_pull_request_details",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id, issue_id: pull_request.id } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
          project_record.issues.pull_requests_only.find(pull_request.id)
        }
      },
      {
        tool_name: "search_code",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id, query: "agent run" } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
          Knowledge::Search.call(project: project_record, query: "agent run", mode: "hybrid", limit: 10)
        }
      },
      {
        tool_name: "search_intents",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id, query: "redis" } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
          project_record.change_intents.where("title ILIKE ?", "%redis%").to_a
        }
      },
      {
        tool_name: "read_repo_file",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id, path: "README.md" } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
        }
      },
      {
        tool_name: "list_repo_tree",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
        }
      },
      {
        tool_name: "grep_repo",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id, query: "def authorize" } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
        }
      },
      {
        tool_name: "write_repo_file",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { repo_path: "/workspace/repo-one", path: "README.md", content: "x", confirmed: true } },
        session: ->(user) {
          create(:chat_session, :workspace, account: user.account, created_by: user, clone_manifest: [
            { project_id: project.id, path: "/workspace/repo-one" }
          ])
        },
        ui_call: ->(user) {
          authorize_record!(user, project, :run_agent?, policy_class: ProjectPolicy)
        }
      },
      {
        tool_name: "apply_patch",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { repo_path: "/workspace/repo-one", patch: "", confirmed: true } },
        session: ->(user) {
          create(:chat_session, :workspace, account: user.account, created_by: user, clone_manifest: [
            { project_id: project.id, path: "/workspace/repo-one" }
          ])
        },
        ui_call: ->(user) {
          authorize_record!(user, project, :run_agent?, policy_class: ProjectPolicy)
        }
      },
      {
        tool_name: "git_diff",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { repo_path: "/workspace/repo-one" } },
        session: ->(user) {
          create(:chat_session, :workspace, account: user.account, created_by: user, clone_manifest: [
            { project_id: project.id, path: "/workspace/repo-one" }
          ])
        },
        ui_call: ->(user) {
          authorize_record!(user, project, :show?, policy_class: ProjectPolicy)
        }
      },
      {
        tool_name: "git_status",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { repo_path: "/workspace/repo-one" } },
        session: ->(user) {
          create(:chat_session, :workspace, account: user.account, created_by: user, clone_manifest: [
            { project_id: project.id, path: "/workspace/repo-one" }
          ])
        },
        ui_call: ->(user) {
          authorize_record!(user, project, :show?, policy_class: ProjectPolicy)
        }
      },
      {
        tool_name: "git_branch_create",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { repo_path: "/workspace/repo-one", branch_name: "feature/test", confirmed: true } },
        session: ->(user) {
          create(:chat_session, :workspace, account: user.account, created_by: user, clone_manifest: [
            { project_id: project.id, path: "/workspace/repo-one" }
          ])
        },
        ui_call: ->(user) {
          authorize_record!(user, project, :run_agent?, policy_class: ProjectPolicy)
        }
      },
      {
        tool_name: "run_shell",
        denied_user: -> { create(:user, :viewer, account: account) },
        arguments: -> { { command: "echo hi", working_dir: "/workspace/repo-one", confirmed: true } },
        session: ->(user) {
          session = create(:chat_session, :workspace, account: user.account, created_by: user,
            project: project, clone_manifest: [ { project_id: project.id, path: "/workspace/repo-one" } ])
          user.account.tenant_setting!.update!(features: user.account.tenant_setting!.features.deep_merge(
            "chat_settings" => { "chat_shell_enabled" => true }
          ))
          session
        },
        ui_call: ->(user) {
          authorize_record!(user, project, :run_agent?, policy_class: ProjectPolicy)
        }
      },
      {
        tool_name: "get_intent",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> {
          change_intent = create(:change_intent, project: project)
          { project_id: project.id, intent_id: change_intent.id }
        },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?)
          project_record.change_intents.order(:id).last
        }
      },
      {
        tool_name: "list_account_memberships",
        denied_user: -> { nil },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, account, :show?, policy_class: AccountPolicy)
          account.account_memberships.includes(:user).order(role: :desc, created_at: :asc).to_a
        }
      },
      {
        tool_name: "invite_account_member",
        denied_user: -> { create(:user, :viewer, account: account) },
        arguments: -> { { email: "blocked@example.com", role: "member", confirmed: true } },
        ui_call: ->(user) {
          authorize_record!(user, account, :update?, policy_class: AccountPolicy)
          Accounts::InviteMember.call(account: account, actor: user, email: "blocked@example.com", role: "member")
        }
      },
      {
        tool_name: "update_account_membership",
        denied_user: -> { create(:user, :viewer, account: account) },
        arguments: -> {
          membership = create(:account_membership, account: account, user: create(:user, account: account), role: :member)
          { membership_id: membership.id, role: "admin", confirmed: true }
        },
        ui_call: ->(user) {
          membership = account.account_memberships.order(:id).last
          authorize_record!(user, account, :update?, policy_class: AccountPolicy)
          Accounts::UpdateMembership.call(account: account, membership: membership, actor: user, role: "admin")
        }
      },
      {
        tool_name: "remove_account_membership",
        denied_user: -> { create(:user, :viewer, account: account) },
        arguments: -> {
          membership = create(:account_membership, account: account, user: create(:user, account: account), role: :member)
          { membership_id: membership.id, confirmed: true }
        },
        ui_call: ->(user) {
          membership = account.account_memberships.order(:id).last
          authorize_record!(user, account, :update?, policy_class: AccountPolicy)
          Accounts::RemoveMembership.call(account: account, membership: membership, actor: user)
        }
      },
      {
        tool_name: "get_user_settings",
        denied_user: -> { nil },
        arguments: -> { {} },
        ui_call: ->(user) {
          settings_owner = create(:user, :member, account: account)
          authorize_record!(user, settings_owner.settings, :edit?)
          settings_owner.settings
        }
      },
      {
        tool_name: "update_user_settings",
        denied_user: -> { nil },
        arguments: -> { { settings: { theme_preference: "dark" }, confirmed: true } },
        ui_call: ->(user) {
          settings_owner = create(:user, :member, account: account)
          authorize_record!(user, settings_owner.settings, :update?)
          settings_owner.settings.update!(theme_preference: "dark")
        }
      },
      {
        tool_name: "get_tenant_settings",
        denied_user: -> { create(:user, :member, account: account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, account, :update?, policy_class: AccountPolicy)
          account.tenant_setting!
        }
      },
      {
        tool_name: "update_tenant_settings",
        denied_user: -> { create(:user, :member, account: account) },
        arguments: -> { { settings: { max_concurrent_runs: 9 }, confirmed: true } },
        ui_call: ->(user) {
          authorize_record!(user, account, :update?, policy_class: AccountPolicy)
          account.tenant_setting!.update!(max_concurrent_runs: 9)
        }
      },
      {
        tool_name: "list_provider_api_keys",
        denied_user: -> { nil },
        arguments: -> { {} },
        ui_call: ->(user) { Pundit.policy_scope!(user, ProviderApiKey).ordered.to_a }
      },
      {
        tool_name: "create_provider_api_key",
        denied_user: -> { nil },
        arguments: -> { { name: "Denied", api_key: "sk", api_service_type: "openai", confirmed: true } },
        ui_call: ->(user) {
          key_owner = create(:user, :member, account: account)
          record = key_owner.provider_api_keys.build
          authorize_record!(user, record, :create?, policy_class: ProviderApiKeyPolicy)
          key_owner.provider_api_keys.create!(name: "Denied", api_key: "sk", api_service_type: "openai")
        }
      },
      {
        tool_name: "update_provider_api_key",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> {
          provider_api_key = create(:provider_api_key, user: create(:user, :member, account: account))
          { provider_api_key_id: provider_api_key.id, attributes: { name: "Denied" }, confirmed: true }
        },
        ui_call: ->(user) {
          provider_api_key = ProviderApiKey.order(:id).last
          record = Pundit.policy_scope!(user, ProviderApiKey).find(provider_api_key.id)
          authorize_record!(user, record, :update?, policy_class: ProviderApiKeyPolicy)
          record.update!(name: "Denied")
        }
      },
      {
        tool_name: "remove_provider_api_key",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> {
          provider_api_key = create(:provider_api_key, user: create(:user, :member, account: account))
          { provider_api_key_id: provider_api_key.id, confirmed: true }
        },
        ui_call: ->(user) {
          provider_api_key = ProviderApiKey.order(:id).last
          record = Pundit.policy_scope!(user, ProviderApiKey).find(provider_api_key.id)
          authorize_record!(user, record, :destroy?, policy_class: ProviderApiKeyPolicy)
          record.destroy!
        }
      },
      {
        tool_name: "list_mcp_server_definitions",
        denied_user: -> { create(:user, :member, account: account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, McpServerDefinition, :index?, policy_class: McpServerDefinitionPolicy)
          Pundit.policy_scope!(user, McpServerDefinition).to_a
        }
      },
      {
        tool_name: "create_mcp_server_definition",
        denied_user: -> { create(:user, :member, account: account) },
        arguments: -> {
          {
            attributes: { name: "Denied", transport: "stdio", install_type: "npx", command: "npx denied" },
            confirmed: true
          }
        },
        ui_call: ->(user) {
          record = account.mcp_server_definitions.build
          authorize_record!(user, record, :create?, policy_class: McpServerDefinitionPolicy)
          account.mcp_server_definitions.create!(name: "Denied", transport: "stdio", install_type: "npx", command: "npx denied")
        }
      },
      {
        tool_name: "update_mcp_server_definition",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> {
          definition = create(:mcp_server_definition, account: account)
          { mcp_server_definition_id: definition.id, attributes: { name: "Denied" }, confirmed: true }
        },
        ui_call: ->(user) {
          definition = McpServerDefinition.order(:id).last
          definition = Pundit.policy_scope!(user, McpServerDefinition).find(definition.id)
          authorize_record!(user, definition, :update?, policy_class: McpServerDefinitionPolicy)
          definition.update!(name: "Denied")
        }
      },
      {
        tool_name: "remove_mcp_server_definition",
        denied_user: -> { create(:user, :admin, account: account) },
        arguments: -> {
          definition = create(:mcp_server_definition, account: account)
          { mcp_server_definition_id: definition.id, confirmed: true }
        },
        ui_call: ->(user) {
          definition = Pundit.policy_scope!(user, McpServerDefinition).order(:id).last
          authorize_record!(user, definition, :destroy?, policy_class: McpServerDefinitionPolicy)
          definition.destroy!
        }
      },
      {
        tool_name: "clone_project",
        denied_user: -> { create(:user, :member, account: other_account) },
        arguments: -> { { project_id: project.id, confirmed: true } },
        ui_call: ->(user) {
          project_record = Pundit.policy_scope!(user, Project).find(project.id)
          authorize_record!(user, project_record, :show?, policy_class: ProjectPolicy)
        }
      }
    ] + operator_tool_scenarios
  end

  describe "authorization parity" do
    it "covers every registered tool" do
      expect(scenarios.map { |scenario| scenario[:tool_name] })
        .to match_array(described_class.all.map(&:tool_name))
    end

    it "denies every registered tool through chat whenever the direct path is denied" do
      scenarios.each do |scenario|
        user = instance_exec(&scenario[:denied_user])
        arguments = instance_exec(&scenario[:arguments])

        chat_error = capture_error do
          described_class.dispatch(
            name: scenario[:tool_name],
            arguments: arguments,
            user: user,
            session: scenario[:session] ? instance_exec(user, &scenario[:session]) : build(:chat_session, account: user&.account || account, created_by: user)
          )
        end

        ui_error = capture_error do
          instance_exec(user, &scenario[:ui_call])
        end

        expect(chat_error).to be_present, "expected chat path denial for #{scenario[:tool_name]}"
        expect(ui_error).to be_present, "expected direct path denial for #{scenario[:tool_name]}"
        expect(normalize_denial(chat_error)).to eq(normalize_denial(ui_error)),
          "expected matching denials for #{scenario[:tool_name]}"
      end
    end
  end

  private

  def operator_tool_scenarios
    [
      {
        tool_name: "operator_console_inventory",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          raise Pundit::NotAuthorizedError unless user&.operator?
        }
      },
      {
        tool_name: "operator_list_accounts",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, Account.new, :index?, policy_class: OperatorConsole::AccountPolicy)
          Pundit.policy_scope!(user, Account, policy_scope_class: OperatorConsole::AccountPolicy::Scope).to_a
        }
      },
      {
        tool_name: "operator_get_account",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          target_account = create(:account)
          { id: target_account.id }
        },
        ui_call: ->(user) {
          target_account = Account.order(:id).last
          authorize_record!(user, target_account, :show?, policy_class: OperatorConsole::AccountPolicy)
        }
      },
      {
        tool_name: "operator_list_account_activity_events",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, AccountActivityEvent.new, :index?, policy_class: OperatorConsole::AccountActivityEventPolicy)
          Pundit.policy_scope!(user, AccountActivityEvent, policy_scope_class: OperatorConsole::AccountActivityEventPolicy::Scope).to_a
        }
      },
      {
        tool_name: "operator_get_account_activity_event",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          event_account = create(:account)
          event = AccountActivityEvent.create!(
            account: event_account,
            action: AccountActivityEvent::ACTION_CATEGORIES.keys.first,
            metadata: {}
          )
          { id: event.id }
        },
        ui_call: ->(user) {
          event = AccountActivityEvent.order(:id).last
          authorize_record!(user, event, :show?, policy_class: OperatorConsole::AccountActivityEventPolicy)
        }
      },
      {
        tool_name: "operator_list_account_memberships",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, AccountMembership.new, :index?, policy_class: OperatorConsole::AccountMembershipPolicy)
          Pundit.policy_scope!(user, AccountMembership, policy_scope_class: OperatorConsole::AccountMembershipPolicy::Scope).to_a
        }
      },
      {
        tool_name: "operator_get_account_membership",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          membership_account = create(:account)
          membership = create(:account_membership, account: membership_account, user: create(:user, account: create(:account)))
          { id: membership.id }
        },
        ui_call: ->(user) {
          membership = AccountMembership.order(:id).last
          authorize_record!(user, membership, :show?, policy_class: OperatorConsole::AccountMembershipPolicy)
        }
      },
      {
        tool_name: "operator_list_pre_commit_requirements",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, PreCommitRequirement.new, :index?, policy_class: OperatorConsole::PreCommitRequirementPolicy)
          Pundit.policy_scope!(user, PreCommitRequirement, policy_scope_class: OperatorConsole::PreCommitRequirementPolicy::Scope).to_a
        }
      },
      {
        tool_name: "operator_get_pre_commit_requirement",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          requirement = create(:pre_commit_requirement, account: create(:account))
          { id: requirement.id }
        },
        ui_call: ->(user) {
          requirement = PreCommitRequirement.order(:id).last
          authorize_record!(user, requirement, :show?, policy_class: OperatorConsole::PreCommitRequirementPolicy)
        }
      },
      {
        tool_name: "operator_list_project_memberships",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, ProjectMembership.new, :index?, policy_class: OperatorConsole::ProjectMembershipPolicy)
          Pundit.policy_scope!(user, ProjectMembership, policy_scope_class: OperatorConsole::ProjectMembershipPolicy::Scope).to_a
        }
      },
      {
        tool_name: "operator_get_project_membership",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          project_account = create(:account)
          project_membership = create(
            :project_membership,
            project: create(:project, account: project_account),
            user: create(:user, account: project_account)
          )
          { id: project_membership.id }
        },
        ui_call: ->(user) {
          project_membership = ProjectMembership.order(:id).last
          authorize_record!(user, project_membership, :show?, policy_class: OperatorConsole::ProjectMembershipPolicy)
        }
      },
      {
        tool_name: "operator_list_style_guides",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, StyleGuide.new, :index?, policy_class: OperatorConsole::StyleGuidePolicy)
          Pundit.policy_scope!(user, StyleGuide, policy_scope_class: OperatorConsole::StyleGuidePolicy::Scope).to_a
        }
      },
      {
        tool_name: "operator_get_style_guide",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          style_guide = create(:style_guide, :global)
          { id: style_guide.id }
        },
        ui_call: ->(user) {
          style_guide = StyleGuide.order(:id).last
          authorize_record!(user, style_guide, :show?, policy_class: OperatorConsole::StyleGuidePolicy)
        }
      },
      {
        tool_name: "operator_list_tenant_settings",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, TenantSetting.new, :index?, policy_class: OperatorConsole::TenantSettingPolicy)
          Pundit.policy_scope!(user, TenantSetting, policy_scope_class: OperatorConsole::TenantSettingPolicy::Scope).to_a
        }
      },
      {
        tool_name: "operator_get_tenant_setting",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          setting = create(:tenant_setting, account: create(:account))
          { id: setting.id }
        },
        ui_call: ->(user) {
          setting = TenantSetting.order(:id).last
          authorize_record!(user, setting, :show?, policy_class: OperatorConsole::TenantSettingPolicy)
        }
      },
      {
        tool_name: "operator_list_users",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> { {} },
        ui_call: ->(user) {
          authorize_record!(user, User.new, :index?, policy_class: OperatorConsole::UserPolicy)
          Pundit.policy_scope!(user, User, policy_scope_class: OperatorConsole::UserPolicy::Scope).to_a
        }
      },
      {
        tool_name: "operator_get_user",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          target_user = create(:user, account: create(:account))
          { id: target_user.id }
        },
        ui_call: ->(user) {
          target_user = User.order(:id).last
          authorize_record!(user, target_user, :show?, policy_class: OperatorConsole::UserPolicy)
        }
      },
      {
        tool_name: "operator_suspend_account",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          target_account = create(:account)
          { account_id: target_account.id, confirmed: true }
        },
        ui_call: ->(user) {
          target_account = Account.order(:id).last
          authorize_record!(user, target_account, :act_on?, policy_class: OperatorConsole::AccountPolicy)
          Avo::Actions::SuspendAccount.new.handle(query: [ target_account ], fields: {}, current_user: user, resource: nil)
        }
      },
      {
        tool_name: "operator_reactivate_account",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          target_account = create(:account, suspended_at: Time.current)
          { account_id: target_account.id, confirmed: true }
        },
        ui_call: ->(user) {
          target_account = Account.order(:id).last
          authorize_record!(user, target_account, :act_on?, policy_class: OperatorConsole::AccountPolicy)
          Avo::Actions::ReactivateAccount.new.handle(query: [ target_account ], fields: {}, current_user: user, resource: nil)
        }
      },
      {
        tool_name: "operator_deactivate_account",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          target_account = create(:account)
          { account_id: target_account.id, confirmed: true }
        },
        ui_call: ->(user) {
          target_account = Account.order(:id).last
          authorize_record!(user, target_account, :act_on?, policy_class: OperatorConsole::AccountPolicy)
          Avo::Actions::DeactivateAccount.new.handle(query: [ target_account ], fields: {}, current_user: user, resource: nil)
        }
      },
      {
        tool_name: "operator_recompress_style_guides",
        denied_user: -> { create(:user, :owner, account: other_account) },
        arguments: -> {
          style_guide = create(:style_guide, :global)
          { style_guide_ids: [ style_guide.id ], confirmed: true }
        },
        ui_call: ->(user) {
          style_guide = StyleGuide.order(:id).last
          authorize_record!(user, style_guide, :act_on?, policy_class: OperatorConsole::StyleGuidePolicy)
          Avo::Actions::RecompressStyleGuides.new.handle(query: [ style_guide ], fields: {}, current_user: user, resource: nil)
        }
      }
    ]
  end

  def capture_error
    yield
    nil
  rescue StandardError => error
    error
  end

  def normalize_denial(error)
    case error
    when ActiveRecord::RecordNotFound
      :record_not_found
    when Pundit::NotAuthorizedError
      :not_authorized
    else
      error&.class
    end
  end

  def authorize_record!(user, record, query, policy_class: nil)
    policy = policy_class ? policy_class.new(user, record) : Pundit.policy!(user, record)
    return record if policy.public_send(query)

    raise Pundit::NotAuthorizedError.new(query: query, record: record, policy: policy)
  end
end
