# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe GithubTokenValidationJob do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, :pending_validation, account: account) }

  describe "GoodJob concurrency" do
    it "serializes validation per GitHub token" do
      config = described_class.good_job_concurrency_config

      expect(config[:total_limit]).to eq(1)
      expect(config[:enqueue_limit]).to eq(1)
      expect(described_class.new(github_token.id).good_job_concurrency_key).to eq("github_token_validation_#{github_token.id}")
    end
  end

  describe "#perform" do
    context "when token is valid" do
      before do
        octokit_client = instance_double(Octokit::Client)
        allow(Octokit::Client).to receive(:new).and_return(octokit_client)
        allow(octokit_client).to receive_messages(
          user: OpenStruct.new(login: "testuser", id: 12345, name: "Test User", email: "test@example.com"),
          scopes: [ "repo", "read:org" ],
          last_response: OpenStruct.new(headers: {})
        )
        allow(octokit_client).to receive(:middleware=)
        allow(octokit_client).to receive_messages(auto_paginate: false, repositories: [])
        allow(octokit_client).to receive(:auto_paginate=)
      end

      it "transitions token to validated" do
        described_class.perform_now(github_token.id)
        expect(github_token.reload.validation_status).to eq("validated")
      end

      it "clears any previous validation error" do
        github_token.update!(validation_error: "old error")
        described_class.perform_now(github_token.id)
        expect(github_token.reload.validation_error).to be_nil
      end

      it "always calls auto-resume after successful validation" do
        allow(GithubTokens::AutoResumeProjects).to receive(:call)

        described_class.perform_now(github_token.id)

        expect(GithubTokens::AutoResumeProjects).to have_received(:call).with(github_token: github_token)
      end
    end

    context "when a previously failed token becomes valid again" do
      let(:github_token) { create(:github_token, :validation_failed, account: account) }

      before do
        octokit_client = instance_double(Octokit::Client)
        allow(Octokit::Client).to receive(:new).and_return(octokit_client)
        allow(octokit_client).to receive_messages(
          user: OpenStruct.new(login: "testuser", id: 12345, name: "Test User", email: "test@example.com"),
          scopes: [ "repo", "read:org" ],
          last_response: OpenStruct.new(headers: {})
        )
        allow(octokit_client).to receive(:middleware=)
        allow(octokit_client).to receive_messages(auto_paginate: false, repositories: [])
        allow(octokit_client).to receive(:auto_paginate=)
      end

      it "auto-resumes projects paused by the token failure" do
        allow(GithubTokens::AutoResumeProjects).to receive(:call)

        described_class.perform_now(github_token.id)

        expect(GithubTokens::AutoResumeProjects).to have_received(:call).with(github_token: github_token)
      end
    end

    context "when token is invalid (auth error)" do
      before do
        octokit_client = instance_double(Octokit::Client)
        allow(Octokit::Client).to receive(:new).and_return(octokit_client)
        allow(octokit_client).to receive(:middleware=)
        allow(octokit_client).to receive(:user).and_raise(Octokit::Unauthorized.new({}))
      end

      it "marks token as failed" do
        described_class.perform_now(github_token.id)
        expect(github_token.reload.validation_status).to eq("failed")
      end

      it "stores the error message" do
        described_class.perform_now(github_token.id)
        expect(github_token.reload.validation_error).to include("invalid or has been revoked")
      end

      it "auto-pauses active projects using the token" do
        project = create(:project, account: account, github_token: github_token)

        described_class.perform_now(github_token.id)

        expect(project.reload.scheduler_paused_at).to be_present
        expect(project.reload.scheduler_pause_reason).to include("failed validation")
      end

      it "auto-pauses projects even when token was already in failed state" do
        github_token.update!(validation_status: "failed", validation_error: "old error")
        project = create(:project, account: account, github_token: github_token)

        described_class.perform_now(github_token.id)

        expect(project.reload.scheduler_paused_at).to be_present
        expect(project.reload.scheduler_pause_reason).to include("failed validation")
      end
    end

    context "when GitHub API returns a server error" do
      before do
        octokit_client = instance_double(Octokit::Client)
        allow(Octokit::Client).to receive(:new).and_return(octokit_client)
        allow(octokit_client).to receive(:middleware=)
        allow(octokit_client).to receive(:user).and_raise(Octokit::ServerError.new({}))
      end

      it "marks token as failed with API error message" do
        described_class.perform_now(github_token.id)
        expect(github_token.reload.validation_status).to eq("failed")
        expect(github_token.reload.validation_error).to include("GitHub API error")
      end

      it "does not auto-pause projects on transient API errors" do
        project = create(:project, account: account, github_token: github_token)

        described_class.perform_now(github_token.id)

        expect(project.reload.scheduler_paused_at).to be_nil
      end
    end

    context "when token record is not found" do
      it "does not raise" do
        expect { described_class.perform_now(-1) }.not_to raise_error
      end
    end

    context "when auto-resume raises an error" do
      let(:github_token) { create(:github_token, :pending_validation, account: account) }

      before do
        octokit_client = instance_double(Octokit::Client)
        allow(Octokit::Client).to receive(:new).and_return(octokit_client)
        allow(octokit_client).to receive_messages(
          user: OpenStruct.new(login: "testuser", id: 12345, name: "Test User", email: "test@example.com"),
          scopes: [ "repo", "read:org" ],
          last_response: OpenStruct.new(headers: {})
        )
        allow(octokit_client).to receive(:middleware=)
        allow(octokit_client).to receive_messages(auto_paginate: false, repositories: [])
        allow(octokit_client).to receive(:auto_paginate=)
        allow(GithubTokens::AutoResumeProjects).to receive(:call).and_raise(ActiveRecord::ConnectionTimeoutError)
        allow(Rails.logger).to receive(:info)
        allow(Rails.logger).to receive(:error)
      end

      it "still marks the token as validated" do
        described_class.perform_now(github_token.id)
        expect(github_token.reload.validation_status).to eq("validated")
      end

      it "logs the auto-resume failure" do
        described_class.perform_now(github_token.id)
        expect(Rails.logger).to have_received(:error).with(
          hash_including(
            message: "github_token_validation.auto_resume_failed",
            github_token_id: github_token.id
          )
        )
      end
    end
  end
end
