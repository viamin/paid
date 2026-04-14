# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DispatchClaudeReviewActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, :pull_request,
      project: project,
      github_number: 42,
      ci_action_dispatched_at: nil)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    issue
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:dispatch_repository_event)
  end

  describe "#execute" do
    before do
      project.update!(review_settings: {
        "enabled" => true,
        "methods" => {
          "ci_action" => {
            "enabled" => true,
            "action_name" => described_class::ACTION_NAME
          }
        }
      })
    end

    it "dispatches the repository event" do
      activity.execute(project_id: project.id, pr_number: 42)

      expect(github_client).to have_received(:dispatch_repository_event).with(
        project.full_name,
        event_type: described_class::EVENT_TYPE,
        client_payload: { pr_number: 42 }
      )
    end

    it "stamps ci_action_dispatched_at after a successful dispatch" do
      activity.execute(project_id: project.id, pr_number: 42)

      expect(issue.reload.ci_action_dispatched_at).to be_within(5.seconds).of(Time.current)
    end

    it "does not stamp ci_action_dispatched_at when dispatch fails" do
      allow(github_client).to receive(:dispatch_repository_event).and_raise(GithubClient::Error, "boom")

      expect {
        activity.execute(project_id: project.id, pr_number: 42)
      }.to raise_error(GithubClient::Error, "boom")

      expect(issue.reload.ci_action_dispatched_at).to be_nil
    end
  end
end
