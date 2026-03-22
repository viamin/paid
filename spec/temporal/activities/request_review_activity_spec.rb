# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RequestReviewActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:github_client) { instance_double(GithubClient) }
  let(:copilot_node_id) { described_class::COPILOT_DEFAULT_NODE_ID }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when reviewers list is empty" do
      it "returns without requesting" do
        result = activity.execute(project_id: project.id, pr_number: 42, reviewers: [])

        expect(result[:requested]).to eq([])
      end
    end

    context "when reviewers contain nil and blank values" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_bot_review)
      end

      it "filters out nil and blank reviewers" do
        activity.execute(project_id: project.id, pr_number: 42, reviewers: [ nil, "", "  ", "copilot" ])

        expect(github_client).to have_received(:request_bot_review)
          .with(project.full_name, 42, bot_node_ids: [ copilot_node_id ])
      end
    end

    context "when reviewers contain duplicates" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_bot_review)
      end

      it "deduplicates case-insensitively" do
        activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "copilot", "Copilot", "COPILOT" ])

        expect(github_client).to have_received(:request_bot_review)
          .with(project.full_name, 42, bot_node_ids: [ copilot_node_id ])
          .once
      end
    end

    context "when reviewer is already pending" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [ "copilot" ] })
      end

      it "skips already-pending reviewers" do
        result = activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "copilot" ])

        expect(result[:requested]).to eq([])
        expect(result[:already_pending]).to eq([ "copilot" ])
      end
    end

    context "when requesting copilot review (bot reviewer)" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_bot_review)
      end

      it "uses GraphQL bot review request with batched node IDs" do
        result = activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "copilot" ])

        expect(result[:requested]).to eq([ "copilot" ])
        expect(github_client).to have_received(:request_bot_review)
          .with(project.full_name, 42, bot_node_ids: [ copilot_node_id ])
      end

      it "does not use REST review request for bots" do
        allow(github_client).to receive(:request_pull_request_review)

        activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "copilot" ])

        expect(github_client).not_to have_received(:request_pull_request_review)
      end
    end

    context "when copilot_bot_node_id is configured" do
      let(:custom_node_id) { "BOT_kgDOCustom" }

      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_bot_review)
        allow(Rails.configuration.x).to receive(:copilot_bot_node_id).and_return(custom_node_id)
      end

      it "uses the configured node ID" do
        activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "copilot" ])

        expect(github_client).to have_received(:request_bot_review)
          .with(project.full_name, 42, bot_node_ids: [ custom_node_id ])
      end
    end

    context "when requesting a human reviewer" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_pull_request_review)
      end

      it "uses REST review request for humans" do
        result = activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "octocat" ])

        expect(result[:requested]).to eq([ "octocat" ])
        expect(github_client).to have_received(:request_pull_request_review)
          .with(project.full_name, 42, reviewers: [ "octocat" ])
      end
    end

    context "when requesting both bot and human reviewers" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_pull_request_review)
        allow(github_client).to receive(:request_bot_review)
      end

      it "routes each to the correct mechanism" do
        result = activity.execute(
          project_id: project.id, pr_number: 42,
          reviewers: [ "copilot", "octocat" ]
        )

        expect(result[:requested]).to contain_exactly("copilot", "octocat")
        expect(github_client).to have_received(:request_bot_review)
          .with(project.full_name, 42, bot_node_ids: [ copilot_node_id ])
        expect(github_client).to have_received(:request_pull_request_review)
          .with(project.full_name, 42, reviewers: [ "octocat" ])
      end
    end

    context "when bot review returns 422 but human succeeds" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_pull_request_review)
        allow(github_client).to receive(:request_bot_review)
          .and_raise(GithubClient::ApiError.new("Copilot not available", status: 422))
      end

      it "returns the human reviewer as successfully requested" do
        result = activity.execute(
          project_id: project.id, pr_number: 42,
          reviewers: [ "copilot", "octocat" ]
        )

        expect(result[:requested]).to eq([ "octocat" ])
      end
    end

    context "when bot-only review returns 422" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_bot_review)
          .and_raise(GithubClient::ApiError.new("Copilot not available", status: 422))
      end

      it "returns empty requested list" do
        result = activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "copilot" ])

        expect(result[:requested]).to eq([])
      end
    end

    context "when human review returns 422" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_pull_request_review)
          .and_raise(GithubClient::ApiError.new("Review cannot be requested", status: 422))
      end

      it "handles gracefully and returns error" do
        result = activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "octocat" ])

        expect(result[:requested]).to eq([])
        expect(result[:error]).to include("Review cannot be requested")
      end
    end

    context "when GitHub returns non-422 error" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_return({ users: [] })
        allow(github_client).to receive(:request_bot_review)
          .and_raise(GithubClient::ApiError.new("Server error", status: 500))
      end

      it "re-raises the error" do
        expect {
          activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "copilot" ])
        }.to raise_error(GithubClient::ApiError)
      end
    end

    context "when fetching pending reviewers fails" do
      before do
        allow(github_client).to receive(:pull_request_review_requests)
          .and_raise(GithubClient::Error, "API error")
        allow(github_client).to receive(:request_bot_review)
      end

      it "proceeds with the request (assumes no pending)" do
        result = activity.execute(project_id: project.id, pr_number: 42, reviewers: [ "copilot" ])

        expect(result[:requested]).to eq([ "copilot" ])
      end
    end
  end
end
