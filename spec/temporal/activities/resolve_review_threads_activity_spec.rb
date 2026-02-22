# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ResolveReviewThreadsActivity do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :running,
      project: project,
      source_pull_request_number: 42,
      custom_prompt: "Fix PR")
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:activity) { described_class.new }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when there are unresolved threads" do
      before do
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_return([
            { id: "thread_1", is_resolved: false, comments: [] },
            { id: "thread_2", is_resolved: true, comments: [] },
            { id: "thread_3", is_resolved: false, comments: [] }
          ])

        allow(github_client).to receive(:resolve_review_thread)
      end

      it "resolves unresolved threads" do
        expect(github_client).to receive(:resolve_review_thread).with("thread_1")
        expect(github_client).to receive(:resolve_review_thread).with("thread_3")
        expect(github_client).not_to receive(:resolve_review_thread).with("thread_2")

        activity.execute(agent_run_id: agent_run.id)
      end

      it "returns resolved and failed counts" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:resolved_count]).to eq(2)
        expect(result[:failed_count]).to eq(0)
        expect(result[:agent_run_id]).to eq(agent_run.id)
      end
    end

    context "when individual thread resolution fails" do
      before do
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_return([
            { id: "thread_1", is_resolved: false, comments: [] },
            { id: "thread_2", is_resolved: false, comments: [] }
          ])

        allow(github_client).to receive(:resolve_review_thread).with("thread_1")
        allow(github_client).to receive(:resolve_review_thread).with("thread_2")
          .and_raise(GithubClient::ApiError.new("GraphQL error"))
      end

      it "continues despite individual failures" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:resolved_count]).to eq(1)
        expect(result[:failed_count]).to eq(1)
      end
    end

    context "when there are no unresolved threads" do
      before do
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_return([
            { id: "thread_1", is_resolved: true, comments: [] }
          ])
      end

      it "returns zero counts" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:resolved_count]).to eq(0)
        expect(result[:failed_count]).to eq(0)
      end
    end
  end
end
