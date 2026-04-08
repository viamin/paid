# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckRateLimitActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:client) { instance_double(GithubClient) }

  before do
    github_token = instance_double(GithubToken, client: client)
    allow(Project).to receive(:find_by).with(id: project.id).and_return(project)
    allow(project).to receive(:github_token).and_return(github_token)
  end

  describe "#execute" do
    it "returns rate limit remaining and low flag when budget is sufficient" do
      allow(client).to receive(:rate_limit_remaining).and_return(500)

      result = activity.execute(project_id: project.id)

      expect(result).to eq(rate_limit_remaining: 500, rate_limit_low: false)
    end

    it "returns rate_limit_low true when remaining is below default threshold" do
      allow(client).to receive(:rate_limit_remaining).and_return(50)

      result = activity.execute(project_id: project.id)

      expect(result).to eq(rate_limit_remaining: 50, rate_limit_low: true)
    end

    it "uses custom threshold when provided" do
      allow(client).to receive(:rate_limit_remaining).and_return(50)

      result = activity.execute(project_id: project.id, threshold: 30)

      expect(result).to eq(rate_limit_remaining: 50, rate_limit_low: false)
    end

    it "returns project_missing when project not found" do
      allow(Project).to receive(:find_by).with(id: -1).and_return(nil)

      result = activity.execute(project_id: -1)

      expect(result).to eq(rate_limit_remaining: 0, rate_limit_low: true, project_missing: true)
    end

    it "re-raises RateLimitError as retryable Temporal error" do
      allow(client).to receive(:rate_limit_remaining)
        .and_raise(GithubClient::RateLimitError.new)

      expect { activity.execute(project_id: project.id) }
        .to raise_error(Temporalio::Error::ApplicationError) { |e|
          expect(e.type).to eq("RateLimit")
        }
    end

    it "logs a warning when rate limit is low" do
      allow(client).to receive(:rate_limit_remaining).and_return(50)

      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "rate_limit.budget_low",
        project_id: project.id,
        remaining: 50,
        threshold: 100
      ))

      activity.execute(project_id: project.id)
    end
  end
end
