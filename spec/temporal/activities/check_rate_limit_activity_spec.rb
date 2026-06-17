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
    allow(client).to receive(:rate_limit_snapshot)
      .and_return(remaining: 500, limit: 5000, reset_at: 1.hour.from_now)
  end

  describe "#execute" do
    it "returns rate limit remaining and low flag when budget is sufficient" do
      result = activity.execute(project_id: project.id)

      expect(result).to eq(rate_limit_remaining: 500, rate_limit_low: false)
    end

    it "returns rate_limit_low true when remaining is below default threshold" do
      allow(client).to receive(:rate_limit_snapshot)
        .and_return(remaining: 50, limit: 5000, reset_at: 1.hour.from_now)

      result = activity.execute(project_id: project.id)

      expect(result).to eq(rate_limit_remaining: 50, rate_limit_low: true)
    end

    it "uses custom threshold when provided" do
      allow(client).to receive(:rate_limit_snapshot)
        .and_return(remaining: 50, limit: 5000, reset_at: 1.hour.from_now)

      result = activity.execute(project_id: project.id, threshold: 30)

      expect(result).to eq(rate_limit_remaining: 50, rate_limit_low: false)
    end

    it "returns project_missing when project not found" do
      allow(Project).to receive(:find_by).with(id: -1).and_return(nil)

      result = activity.execute(project_id: -1)

      expect(result).to eq(rate_limit_remaining: 0, rate_limit_low: true, project_missing: true)
    end

    it "re-raises RateLimitError as retryable Temporal error" do
      allow(client).to receive(:rate_limit_snapshot)
        .and_raise(GithubClient::RateLimitError.new)

      expect { activity.execute(project_id: project.id) }
        .to raise_error(Temporalio::Error::ApplicationError) { |e|
          expect(e.type).to eq("RateLimit")
        }
    end

    it "logs a warning when rate limit is low" do
      allow(client).to receive(:rate_limit_snapshot)
        .and_return(remaining: 50, limit: 5000, reset_at: 1.hour.from_now)

      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "rate_limit.budget_low",
        project_id: project.id,
        remaining: 50,
        threshold: 100
      ))

      activity.execute(project_id: project.id)
    end
  end

  describe "rate-limit usage recording" do
    it "records observed quota for PAT-backed projects under the token endpoint" do
      allow(project).to receive(:client).and_return(client)
      reset_at = 1.hour.from_now
      allow(client).to receive(:rate_limit_snapshot)
        .and_return(remaining: 4500, limit: 5000, reset_at: reset_at)

      activity.execute(project_id: project.id)

      state = GithubHealthState.find_by(endpoint: project.github_health_endpoint)
      expect(state.rate_limit_remaining).to eq(4500)
      expect(state.rate_limit_limit).to eq(5000)
      expect(state.rate_limit_reset_at).to be_present
      expect(state.rate_limit_observed_at).to be_present
    end

    it "records observed quota for App-backed projects under the installation endpoint" do
      app_project = create(:project, :with_github_installation)
      allow(Project).to receive(:find_by).with(id: app_project.id).and_return(app_project)
      allow(app_project).to receive(:client).and_return(client)
      allow(client).to receive(:rate_limit_snapshot)
        .and_return(remaining: 12000, limit: 15000, reset_at: 1.hour.from_now)

      activity.execute(project_id: app_project.id)

      endpoint = GithubHealthState.endpoint_for_github_installation(
        app_project.github_installation.github_installation_id
      )
      state = GithubHealthState.find_by(endpoint: endpoint)
      expect(state.rate_limit_remaining).to eq(12000)
      expect(state.rate_limit_limit).to eq(15000)
      expect(app_project.github_auth_source).to eq("app")
    end

    it "keeps recording best-effort and still returns the probe result when recording fails" do
      allow(project).to receive(:client).and_return(client)
      allow(GithubHealthState).to receive(:current).and_raise(StandardError, "boom")

      result = activity.execute(project_id: project.id)

      expect(result).to eq(rate_limit_remaining: 500, rate_limit_low: false)
    end

    it "does not overwrite previously recorded quota when a transport error makes remaining=0 and limit=nil" do
      allow(project).to receive(:client).and_return(client)

      # Seed a previously observed reading
      state = GithubHealthState.current(endpoint: project.github_health_endpoint)
      state.update!(rate_limit_remaining: 4000, rate_limit_limit: 5000, rate_limit_observed_at: 5.minutes.ago)

      # Simulate transport/auth failure: snapshot returns 0 remaining and nil limit
      allow(client).to receive(:rate_limit_snapshot)
        .and_return(remaining: 0, limit: nil, reset_at: nil)

      result = activity.execute(project_id: project.id)

      # Workflow result is unaffected
      expect(result).to eq(rate_limit_remaining: 0, rate_limit_low: true)

      # Previously observed quota must be preserved — not overwritten with the misleading 0/nil reading
      state.reload
      expect(state.rate_limit_remaining).to eq(4000)
      expect(state.rate_limit_limit).to eq(5000)
    end
  end
end
