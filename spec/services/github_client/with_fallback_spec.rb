# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubClient::WithFallback do
  let(:account) { create(:account) }
  let(:project) do
    create(:project, :with_github_installation, account:, allowed_github_usernames: [ "viamin" ])
  end
  let(:primary) { instance_double(GithubClient) }
  let(:fallback) { instance_double(GithubClient) }
  let(:logger_output) { StringIO.new }
  let(:logger) do
    Logger.new(logger_output).tap do |log|
      log.formatter = ->(_severity, _datetime, _progname, msg) { "#{msg}\n" }
    end
  end
  let(:wrapper) { described_class.new(primary:, fallback:, project:, logger:) }

  describe "#authenticated_login" do
    it "returns the primary login when the primary credential is trusted" do
      allow(primary).to receive(:authenticated_login).and_return("viamin")

      expect(wrapper.authenticated_login).to eq("viamin")
      expect(fallback).not_to receive(:authenticated_login)
    end

    it "returns the primary login when the primary is untrusted and the fallback is trusted" do
      allow(primary).to receive(:authenticated_login).and_return("paid-agents[bot]")

      expect(wrapper.authenticated_login).to eq("paid-agents[bot]")
      expect(fallback).not_to receive(:authenticated_login)
    end

    it "returns the primary login when neither credential is trusted" do
      allow(primary).to receive(:authenticated_login).and_return("paid-agents[bot]")
      allow(fallback).to receive(:authenticated_login).and_return("someone-else")

      expect(wrapper.authenticated_login).to eq("paid-agents[bot]")
    end

    it "returns nil when both credentials fail to resolve an identity" do
      allow(primary).to receive(:authenticated_login).and_return(nil)
      allow(fallback).to receive(:authenticated_login).and_return(nil)

      expect(wrapper.authenticated_login).to be_nil
    end

    it "returns nil when primary identity lookup raises" do
      allow(primary).to receive(:authenticated_login).and_raise(GithubClient::AuthenticationError)

      expect(wrapper.authenticated_login).to be_nil
      expect(fallback).not_to receive(:authenticated_login)
    end
  end

  describe "#trusted_human_mutation_client" do
    it "selects the trusted fallback directly when the primary is untrusted" do
      allow(primary).to receive(:authenticated_login).and_return("paid-agents[bot]")
      allow(fallback).to receive(:authenticated_login).and_return("viamin")

      expect(wrapper.trusted_human_mutation_client).to eq(fallback)
    end

    it "preserves primary-first fallback behavior when the primary is trusted" do
      allow(primary).to receive(:authenticated_login).and_return("viamin")

      expect(wrapper.trusted_human_mutation_client).to eq(wrapper)
      expect(fallback).not_to receive(:authenticated_login)
    end
  end

  describe "method delegation" do
    it "passes through to the primary when no error is raised" do
      expect(primary).to receive(:update_issue).with("owner/repo", 42, title: "X").and_return(:result)

      expect(wrapper.update_issue("owner/repo", 42, title: "X")).to eq(:result)
    end

    it "passes blocks to the primary" do
      expect(primary).to receive(:issues).and_yield(:issue_a).and_yield(:issue_b)

      results = []
      wrapper.issues("owner/repo") { |i| results << i }
      expect(results).to eq([ :issue_a, :issue_b ])
    end

    it "reports that it responds to methods the primary responds to" do
      allow(primary).to receive(:update_issue)
      allow(primary).to receive(:merge_pull_request)

      expect(wrapper).to respond_to(:update_issue)
      expect(wrapper).to respond_to(:authenticated_login)
      expect(wrapper).to respond_to(:merge_pull_request)
    end
  end

  describe "permission fallback retry" do
    it "retries with the fallback when the primary raises NotFoundError" do
      expect(primary).to receive(:update_issue)
        .with("owner/repo", 42, title: "X")
        .and_raise(GithubClient::NotFoundError, "Not Found")
      expect(fallback).to receive(:update_issue)
        .with("owner/repo", 42, title: "X")
        .and_return(:retried_result)

      expect(wrapper.update_issue("owner/repo", 42, title: "X")).to eq(:retried_result)
    end

    it "retries when the primary raises ApiError with status 403" do
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::ApiError.new("forbidden", status: 403))
      expect(fallback).to receive(:update_issue).and_return(:retried_result)

      expect(wrapper.update_issue("owner/repo", 42, title: "X")).to eq(:retried_result)
    end

    # @spec GITHUB-SYNC-016
    it "retries GraphQL reads when the primary raises a permission error" do
      expect(primary).to receive(:review_threads)
        .with("owner/repo", 42)
        .and_raise(GithubClient::ApiError.new("Resource not accessible by integration", status: 403))
      expect(fallback).to receive(:review_threads).with("owner/repo", 42).and_return([ :thread ])

      expect(wrapper.review_threads("owner/repo", 42)).to eq([ :thread ])
    end

    it "does not retry when the primary raises AuthenticationError" do
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::AuthenticationError, "Invalid token")
      expect(fallback).not_to receive(:update_issue)

      expect { wrapper.update_issue("owner/repo", 42, title: "X") }
        .to raise_error(GithubClient::AuthenticationError, /Invalid token/)
    end

    it "does not retry when the primary raises RateLimitError" do
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::RateLimitError.new(Time.now + 60))
      expect(fallback).not_to receive(:update_issue)

      expect { wrapper.update_issue("owner/repo", 42, title: "X") }
        .to raise_error(GithubClient::RateLimitError)
    end

    it "does not retry ApiError with status 422" do
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::ApiError.new("unprocessable", status: 422))
      expect(fallback).not_to receive(:update_issue)

      expect { wrapper.update_issue("owner/repo", 42, title: "X") }
        .to raise_error(GithubClient::ApiError)
    end

    it "does not retry ApiError with status 409" do
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::ApiError.new("conflict", status: 409))
      expect(fallback).not_to receive(:update_issue)

      expect { wrapper.update_issue("owner/repo", 42, title: "X") }
        .to raise_error(GithubClient::ApiError)
    end

    it "does not retry ApiError with status 500" do
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::ApiError.new("server error", status: 500))
      expect(fallback).not_to receive(:update_issue)

      expect { wrapper.update_issue("owner/repo", 42, title: "X") }
        .to raise_error(GithubClient::ApiError)
    end

    it "does not retry when no fallback is configured" do
      solo = described_class.new(primary:, fallback: nil, project:, logger:)
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::NotFoundError, "Not Found")

      expect { solo.update_issue("owner/repo", 42, title: "X") }
        .to raise_error(GithubClient::NotFoundError)
    end

    it "surfaces the primary's original error when the fallback also raises" do
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::ApiError.new("forbidden primary", status: 403))
      expect(fallback).to receive(:update_issue)
        .and_raise(GithubClient::ApiError.new("fallback forbidden", status: 403))

      expect { wrapper.update_issue("owner/repo", 42, title: "X") }
        .to raise_error(GithubClient::ApiError, /forbidden primary/)
    end

    it "retries only once even when the fallback raises a retryable error" do
      expect(primary).to receive(:update_issue)
        .and_raise(GithubClient::NotFoundError)
      expect(fallback).to receive(:update_issue)
        .once
        .and_raise(GithubClient::NotFoundError)

      expect { wrapper.update_issue("owner/repo", 42, title: "X") }
        .to raise_error(GithubClient::NotFoundError)
    end
  end

  describe "fallback observability" do
    it "logs each fallback use at warn level with operation and project context" do
      allow(primary).to receive(:update_issue)
        .and_raise(GithubClient::NotFoundError, "Not Found")
      allow(fallback).to receive(:update_issue).and_return(:result)

      wrapper.update_issue("owner/repo", 42, title: "X")

      log_lines = logger_output.string.lines
      expect(log_lines.size).to eq(1)
      expect(log_lines.first).to include("github_client.pat_fallback_used")
      expect(log_lines.first).to include("project_id: #{project.id}")
      expect(log_lines.first).to include('operation: "update_issue"')
      expect(log_lines.first).to include('primary_error_class: "GithubClient::NotFoundError"')
    end

    it "does not log when the primary succeeds without a fallback retry" do
      allow(primary).to receive(:update_issue).and_return(:result)

      wrapper.update_issue("owner/repo", 42, title: "X")

      expect(logger_output.string).to be_empty
    end
  end
end
