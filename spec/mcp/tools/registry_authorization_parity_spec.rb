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
      }
    ]
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
            session: build(:chat_session, account: user&.account || account, created_by: user)
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
