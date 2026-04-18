# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::CacheInvalidator do
  let(:project) { create(:project) }
  let(:repo) { project.full_name }
  let(:github_client) { instance_double(GithubClient) }
  let(:cache_service) { Github::CacheService.new(client: github_client) }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe ".call" do
    context "with pull_request event" do
      let(:payload) do
        {
          "action" => "opened",
          "pull_request" => { "number" => 42 },
          "repository" => { "id" => project.github_id, "full_name" => repo }
        }
      end

      it "invalidates the pull request cache" do
        allow(github_client).to receive(:pull_request).with(repo, 42).and_return("original", "fresh")

        cache_service.pull_request(repo, 42)
        described_class.call(project: project, event: "pull_request", payload: payload)

        expect(cache_service.pull_request(repo, 42)).to eq("fresh")
      end
    end

    context "with pull_request_review event" do
      let(:payload) do
        {
          "action" => "submitted",
          "pull_request" => { "number" => 10 },
          "review" => { "state" => "approved" },
          "repository" => { "id" => project.github_id }
        }
      end

      it "invalidates the pull request cache" do
        allow(github_client).to receive(:pull_request).with(repo, 10).and_return("original", "fresh")

        cache_service.pull_request(repo, 10)
        described_class.call(project: project, event: "pull_request_review", payload: payload)

        expect(cache_service.pull_request(repo, 10)).to eq("fresh")
      end
    end

    context "with issues event" do
      let(:payload) do
        {
          "action" => "opened",
          "issue" => { "number" => 5 },
          "repository" => { "id" => project.github_id }
        }
      end

      it "invalidates the issue cache" do
        allow(github_client).to receive(:issue).with(repo, 5).and_return("original", "fresh")

        cache_service.issue(repo, 5)
        described_class.call(project: project, event: "issues", payload: payload)

        expect(cache_service.issue(repo, 5)).to eq("fresh")
      end
    end

    context "with issue_comment event on a PR" do
      let(:payload) do
        {
          "action" => "created",
          "issue" => {
            "number" => 42,
            "pull_request" => { "url" => "https://api.github.com/repos/#{repo}/pulls/42" }
          },
          "comment" => { "id" => 1, "body" => "Nice!" },
          "repository" => { "id" => project.github_id }
        }
      end

      it "invalidates the pull request cache" do
        allow(github_client).to receive(:pull_request).with(repo, 42).and_return("original", "fresh")

        cache_service.pull_request(repo, 42)
        described_class.call(project: project, event: "issue_comment", payload: payload)

        expect(cache_service.pull_request(repo, 42)).to eq("fresh")
      end
    end

    context "with issue_comment event on an issue" do
      let(:payload) do
        {
          "action" => "created",
          "issue" => { "number" => 5 },
          "comment" => { "id" => 1, "body" => "Comment" },
          "repository" => { "id" => project.github_id }
        }
      end

      it "invalidates the issue cache" do
        allow(github_client).to receive(:issue).with(repo, 5).and_return("original", "fresh")

        cache_service.issue(repo, 5)
        described_class.call(project: project, event: "issue_comment", payload: payload)

        expect(cache_service.issue(repo, 5)).to eq("fresh")
      end
    end

    context "with push event" do
      let(:payload) do
        {
          "ref" => "refs/heads/main",
          "repository" => { "id" => project.github_id }
        }
      end

      it "invalidates repo metadata cache" do
        allow(github_client).to receive(:repository).with(repo).and_return("original", "fresh")

        cache_service.repository(repo)
        described_class.call(project: project, event: "push", payload: payload)

        expect(cache_service.repository(repo)).to eq("fresh")
      end
    end

    context "with nil project" do
      it "does nothing" do
        expect {
          described_class.call(project: nil, event: "push", payload: {})
        }.not_to raise_error
      end
    end

    context "with unhandled event" do
      it "does nothing" do
        expect {
          described_class.call(project: project, event: "ping", payload: {})
        }.not_to raise_error
      end
    end
  end
end
