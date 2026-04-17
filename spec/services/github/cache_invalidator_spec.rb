# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::CacheInvalidator do
  let(:project) { create(:project) }
  let(:repo) { project.full_name }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  # Cache keys match the format used by Github::CacheService:
  # github/<type>/<owner>/<repo>[/<number>]
  def pr_cache_key(number)
    "github/pull_request/#{repo.downcase}/#{number}"
  end

  def issue_cache_key(number)
    "github/issue/#{repo.downcase}/#{number}"
  end

  def repo_cache_key
    "github/repository/#{repo.downcase}"
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
        Rails.cache.write(pr_cache_key(42), "cached_pr")

        described_class.call(project: project, event: "pull_request", payload: payload)

        expect(Rails.cache.read(pr_cache_key(42))).to be_nil
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
        Rails.cache.write(pr_cache_key(10), "cached_pr")

        described_class.call(project: project, event: "pull_request_review", payload: payload)

        expect(Rails.cache.read(pr_cache_key(10))).to be_nil
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
        Rails.cache.write(issue_cache_key(5), "cached_issue")

        described_class.call(project: project, event: "issues", payload: payload)

        expect(Rails.cache.read(issue_cache_key(5))).to be_nil
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
        Rails.cache.write(pr_cache_key(42), "cached_pr")

        described_class.call(project: project, event: "issue_comment", payload: payload)

        expect(Rails.cache.read(pr_cache_key(42))).to be_nil
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
        Rails.cache.write(issue_cache_key(5), "cached_issue")

        described_class.call(project: project, event: "issue_comment", payload: payload)

        expect(Rails.cache.read(issue_cache_key(5))).to be_nil
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
        Rails.cache.write(repo_cache_key, "cached_repo")

        described_class.call(project: project, event: "push", payload: payload)

        expect(Rails.cache.read(repo_cache_key)).to be_nil
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
