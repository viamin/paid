# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe GithubTokenHealthCheckJob do
  let(:account) { create(:account) }

  def stub_valid_octokit
    octokit_client = instance_double(Octokit::Client)
    allow(Octokit::Client).to receive(:new).and_return(octokit_client)
    allow(octokit_client).to receive(:middleware=)
    allow(octokit_client).to receive_messages(
      user: OpenStruct.new(login: "testuser", id: 12345, name: "Test User", email: "test@example.com"),
      scopes: [ "repo", "read:org" ],
      last_response: OpenStruct.new(headers: {}),
      auto_paginate: false,
      repositories: []
    )
    allow(octokit_client).to receive(:auto_paginate=)
    octokit_client
  end

  def stub_auth_error_octokit
    octokit_client = instance_double(Octokit::Client)
    allow(Octokit::Client).to receive(:new).and_return(octokit_client)
    allow(octokit_client).to receive(:middleware=)
    allow(octokit_client).to receive(:user).and_raise(Octokit::Unauthorized.new({}))
    octokit_client
  end

  def stub_api_error_octokit
    octokit_client = instance_double(Octokit::Client)
    allow(Octokit::Client).to receive(:new).and_return(octokit_client)
    allow(octokit_client).to receive(:middleware=)
    allow(octokit_client).to receive(:user).and_raise(Octokit::ServerError.new({}))
    octokit_client
  end

  describe "#perform" do
    context "when token is valid" do
      let!(:token) { create(:github_token, :pending_validation, account: account) }

      before { stub_valid_octokit }

      it "validates the token successfully" do
        described_class.perform_now
        expect(token.reload.validation_status).to eq("validated")
      end

      it "clears any previous validation error" do
        token.update!(validation_error: "old error")
        described_class.perform_now
        expect(token.reload.validation_error).to be_nil
      end
    end

    context "when token has been revoked (auth error)" do
      let!(:token) { create(:github_token, :pending_validation, account: account) }

      before { stub_auth_error_octokit }

      it "marks token as failed" do
        described_class.perform_now
        expect(token.reload.validation_status).to eq("failed")
      end

      it "stores a clear error message" do
        described_class.perform_now
        expect(token.reload.validation_error).to include("revoked or expired")
      end
    end

    context "when GitHub returns a transient API error" do
      let!(:token) { create(:github_token, :pending_validation, account: account) }

      before { stub_api_error_octokit }

      it "does not mark token as failed" do
        described_class.perform_now
        expect(token.reload.validation_status).not_to eq("failed")
      end

      it "restores token to pending status" do
        described_class.perform_now
        expect(token.reload.validation_status).to eq("pending")
      end

      it "clears validation error" do
        described_class.perform_now
        expect(token.reload.validation_error).to be_nil
      end
    end

    context "when GitHub returns a rate limit error" do
      let!(:token) { create(:github_token, :pending_validation, account: account) }

      before do
        octokit_client = instance_double(Octokit::Client)
        allow(Octokit::Client).to receive(:new).and_return(octokit_client)
        allow(octokit_client).to receive(:middleware=)
        allow(octokit_client).to receive(:user).and_raise(Octokit::TooManyRequests.new({}))
        rate_limit = instance_double(Octokit::RateLimit, resets_at: Time.now + 3600)
        allow(octokit_client).to receive(:rate_limit).and_return(rate_limit)
      end

      it "does not mark token as failed" do
        described_class.perform_now
        expect(token.reload.validation_status).not_to eq("failed")
      end

      it "restores token to pending status" do
        described_class.perform_now
        expect(token.reload.validation_status).to eq("pending")
      end
    end

    context "when token was recently validated" do
      it "skips the token" do
        create(:github_token, account: account, validation_status: "validated", updated_at: 1.hour.ago)
        expect(Octokit::Client).not_to receive(:new)
        described_class.perform_now
      end
    end

    context "when token was validated more than 24 hours ago" do
      let!(:token) do
        create(:github_token, account: account, validation_status: "validated")
      end

      before do
        token.update_column(:updated_at, 25.hours.ago)
        stub_valid_octokit
      end

      it "re-validates the token" do
        described_class.perform_now
        expect(token.reload.validation_status).to eq("validated")
        expect(token.reload.updated_at).to be > 1.minute.ago
      end
    end

    context "when token is revoked" do
      it "skips revoked tokens" do
        create(:github_token, :revoked, account: account)
        expect(Octokit::Client).not_to receive(:new)
        described_class.perform_now
      end
    end

    context "when token is expired" do
      it "skips expired tokens" do
        create(:github_token, :expired, account: account)
        expect(Octokit::Client).not_to receive(:new)
        described_class.perform_now
      end
    end

    context "with multiple tokens" do
      let!(:valid_token) { create(:github_token, :pending_validation, account: account, name: "valid") }
      let!(:recently_validated) do
        create(:github_token, account: account, validation_status: "validated",
               updated_at: 1.hour.ago, name: "recent")
      end

      before { stub_valid_octokit }

      it "checks only tokens that need validation" do
        described_class.perform_now

        expect(valid_token.reload.validation_status).to eq("validated")
        # recently_validated should remain unchanged (skipped)
        expect(recently_validated.reload.updated_at).to be < 30.minutes.ago
      end
    end

    it "logs completion with metrics" do
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "github_token.health_check.completed",
          tokens_checked: 0,
          tokens_failed: 0,
          tokens_skipped: 0
        )
      )
    end
  end
end
