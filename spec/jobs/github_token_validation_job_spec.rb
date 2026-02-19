# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe GithubTokenValidationJob do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, :pending_validation, account: account) }

  describe "#perform" do
    context "when token is valid" do
      before do
        octokit_client = instance_double(Octokit::Client)
        allow(Octokit::Client).to receive(:new).and_return(octokit_client)
        allow(octokit_client).to receive_messages(
          user: OpenStruct.new(login: "testuser", id: 12345, name: "Test User", email: "test@example.com"),
          scopes: [ "repo", "read:org" ]
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
    end

    context "when token record is not found" do
      it "does not raise" do
        expect { described_class.perform_now(-1) }.not_to raise_error
      end
    end
  end
end
