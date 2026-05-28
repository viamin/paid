# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExceptionHandler::IssueFiler do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:incident) { create(:exception_incident, :with_project, account: account, project: project) }
  let(:client) { instance_double(GithubClient) }
  let(:github_token) { instance_double(GithubToken, client: client) }
  let(:issue_url) { "https://github.com/acme/widgets/issues/12" }
  let(:gh_issue) { double(html_url: issue_url, number: 12) }

  before do
    clean_up_test_data
    allow(project).to receive(:github_token).and_return(github_token)
  end

  after do
    clean_up_test_data
  end

  def clean_up_test_data
    ExceptionIncident.delete_all
    WorkflowState.delete_all
    ServiceContainerMetric.delete_all
    ProjectServiceContainer.delete_all
    ServiceContainer.delete_all
    Project.delete_all
    GithubToken.delete_all
    Runner.delete_all
    ProviderState.delete_all
    AccountMembership.delete_all
    TenantSetting.delete_all
    User.delete_all
    Account.delete_all
  end

  describe ".call" do
    it "creates an issue when the incident is not filed yet" do
      allow(client).to receive(:create_issue).and_return(gh_issue)

      result = described_class.call(incident: incident, project: project)

      expect(result).to eq(issue_url)
      expect(incident.reload.github_issue_url).to eq(issue_url)
      expect(incident.github_issue_number).to eq(12)
      expect(incident.action_taken).to eq("issue_filed")
    end

    it "retries issue creation when a previous attempt claimed but did not complete" do
      incident.update_columns(
        action_taken: "filing",
        github_issue_number: nil,
        updated_at: (ExceptionHandler::IssueFiler::CLAIM_STALE_AFTER + 1.second).ago
      )
      allow(gh_issue).to receive_messages(html_url: "https://github.com/acme/widgets/issues/34", number: 34)
      allow(client).to receive(:create_issue).and_return(gh_issue)

      described_class.call(incident: incident, project: project)

      incident.reload
      expect(client).to have_received(:create_issue).once
      expect(incident.github_issue_url).to eq("https://github.com/acme/widgets/issues/34")
      expect(incident.github_issue_number).to eq(34)
    end

    it "adds a comment instead of creating a duplicate issue for concurrent calls when the first filing is slow" do
      incident
      project

      create_issue_started, release_create_issue = stub_slow_issue_creation
      allow(client).to receive(:add_comment)

      thread_one = concurrent_call
      create_issue_started.pop
      expect {
        described_class.call(incident: ExceptionIncident.find(incident.id), project: project)
      }.to raise_error(ExceptionHandler::IssueFiler::RetryableFilingInProgress)
      release_create_issue << true

      thread_one.value
      described_class.call(incident: ExceptionIncident.find(incident.id), project: project)

      expect(client).to have_received(:create_issue).once
      expect(client).to have_received(:add_comment).once.with(project.full_name, 56, kind_of(String))
      expect(incident.reload.github_issue_number).to eq(56)
    end

    it "treats an incident with only github_issue_url as already filed" do
      incident.update_columns(
        github_issue_url: "https://github.com/acme/widgets/issues/78",
        github_issue_number: nil,
        action_taken: "issue_filed"
      )
      allow(client).to receive(:create_issue)
      allow(client).to receive(:add_comment)

      described_class.call(incident: incident, project: project)

      expect(client).to have_received(:add_comment).with(project.full_name, 78, kind_of(String))
      expect(client).not_to have_received(:create_issue)
    end

    it "releases the filing claim after a GitHub failure so a later retry can file" do
      allow(client).to receive(:create_issue).and_raise(GithubClient::Error, "timeout")

      described_class.call(incident: incident, project: project)

      expect(incident.reload.action_taken).to eq("notified")
    end

    def concurrent_call
      Thread.new do
        TenantContext.with_system_access do
          described_class.call(incident: ExceptionIncident.find(incident.id), project: project)
        end
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end
    end

    def stub_slow_issue_creation
      allow(gh_issue).to receive_messages(html_url: "https://github.com/acme/widgets/issues/56", number: 56)
      create_issue_started = Queue.new
      release_create_issue = Queue.new
      allow(client).to receive(:create_issue) do
        create_issue_started << true
        release_create_issue.pop
        gh_issue
      end

      [ create_issue_started, release_create_issue ]
    end
  end
end
