# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Github::CacheWarmer do
  let(:project) { create(:project) }
  let(:github_client) { instance_double(GithubClient) }
  let(:repo) { project.full_name }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  before do
    allow(project).to receive(:github_credential).and_return("ghp_test123")
    allow(project).to receive(:client).and_return(github_client)
    allow(github_client).to receive_messages(
      repository: OpenStruct.new(id: 1),
      labels: [],
      issues: [],
      pull_requests: []
    )
  end

  describe ".call" do
    it "warms repository metadata" do
      described_class.call(project: project)

      expect(github_client).to have_received(:repository).with(repo)
    end

    it "warms labels" do
      described_class.call(project: project)

      expect(github_client).to have_received(:labels).with(repo)
    end

    it "warms open issues" do
      described_class.call(project: project)

      expect(github_client).to have_received(:issues).with(repo, labels: nil, state: "open")
    end

    it "warms open pull requests" do
      described_class.call(project: project)

      expect(github_client).to have_received(:pull_requests).with(repo, state: "open")
    end

    it "logs a summary" do
      allow(Rails.logger).to receive(:info)

      described_class.call(project: project)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "github_cache.warmed",
          warmed_count: 4
        )
      )
    end

    context "when a fetch fails" do
      before do
        allow(github_client).to receive(:labels)
          .and_raise(GithubClient::ApiError.new("API error"))
      end

      it "continues warming other resources" do
        described_class.call(project: project)

        expect(github_client).to have_received(:repository)
        expect(github_client).to have_received(:issues)
        expect(github_client).to have_received(:pull_requests)
      end

      it "logs the failure" do
        allow(Rails.logger).to receive(:warn)
        allow(Rails.logger).to receive(:info)

        described_class.call(project: project)

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "github_cache.warm_failed",
            resource: :labels
          )
        )
      end

      it "reports partial warming count" do
        allow(Rails.logger).to receive(:info)
        allow(Rails.logger).to receive(:warn)

        described_class.call(project: project)

        expect(Rails.logger).to have_received(:info).with(
          hash_including(warmed_count: 3)
        )
      end
    end

    context "when token is inactive" do
      before do
        allow(project).to receive(:github_credential).and_return(nil)
      end

      it "does nothing" do
        described_class.call(project: project)

        expect(github_client).not_to have_received(:repository)
      end
    end
  end
end
