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
    allow(project).to receive(:github_token).and_return(github_token)
  end

  after do
    ExceptionIncident.delete_all
    Project.delete_all
    GithubToken.delete_all
    Provider.delete_all
    ProviderState.delete_all
    AccountMembership.delete_all
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

    it "retries issue creation when a previous attempt left only github_issue_url populated" do
      incident.update_columns(github_issue_url: "filing", github_issue_number: nil)
      allow(gh_issue).to receive_messages(html_url: "https://github.com/acme/widgets/issues/34", number: 34)
      allow(client).to receive(:create_issue).and_return(gh_issue)

      described_class.call(incident: incident, project: project)

      incident.reload
      expect(client).to have_received(:create_issue).once
      expect(incident.github_issue_url).to eq("https://github.com/acme/widgets/issues/34")
      expect(incident.github_issue_number).to eq(34)
    end

    it "adds a comment instead of creating a duplicate issue for concurrent calls" do
      allow(gh_issue).to receive_messages(html_url: "https://github.com/acme/widgets/issues/56", number: 56)
      create_issue_started = Queue.new
      release_create_issue = Queue.new
      allow(client).to receive(:create_issue) do
        create_issue_started << true
        release_create_issue.pop
        gh_issue
      end
      allow(client).to receive(:add_comment)

      thread_one = concurrent_call
      create_issue_started.pop
      thread_two = concurrent_call
      release_create_issue << true

      [ thread_one, thread_two ].each(&:value)

      expect(client).to have_received(:create_issue).once
      expect(client).to have_received(:add_comment).once.with(project.full_name, 56, kind_of(String))
      expect(incident.reload.github_issue_number).to eq(56)
    end

    def concurrent_call
      Thread.new do
        TenantContext.with_system_access do
          described_class.call(incident: ExceptionIncident.find(incident.id), project: project)
        end
      end
    end
  end
end
