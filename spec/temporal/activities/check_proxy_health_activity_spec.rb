# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckProxyHealthActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  around do |example|
    original_paid_proxy_url = ENV["PAID_PROXY_URL"]
    ENV["PAID_PROXY_URL"] = "http://localhost:3000"
    example.run
  ensure
    ENV["PAID_PROXY_URL"] = original_paid_proxy_url
  end

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end

    it "is a Temporal activity definition" do
      expect(described_class).to be < Temporalio::Activity::Definition
    end
  end

  describe "constants" do
    it "defines MAX_WAIT_SECONDS" do
      expect(described_class::MAX_WAIT_SECONDS).to eq(600)
    end

    it "defines INITIAL_POLL_INTERVAL" do
      expect(described_class::INITIAL_POLL_INTERVAL).to eq(5)
    end

    it "defines MAX_POLL_INTERVAL" do
      expect(described_class::MAX_POLL_INTERVAL).to eq(30)
    end
  end

  describe "#execute" do
    context "when proxy is healthy" do
      it "returns healthy: true" do
        stub_health_check(200)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:healthy]).to be true
      end
    end

    context "when proxy is unhealthy" do
      it "raises a retryable ApplicationError" do
        stub_health_check(503)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("ProxyUnhealthy")
          expect(error.non_retryable).to be false
        }
      end
    end

    context "when PAID_PROXY_URL is not set" do
      around do |example|
        original_paid_proxy_url = ENV["PAID_PROXY_URL"]
        ENV.delete("PAID_PROXY_URL")
        example.run
      ensure
        ENV["PAID_PROXY_URL"] = original_paid_proxy_url
      end

      before do
        allow(Rails.application.config.x).to receive(:proxy_url).and_return(nil)
      end

      it "returns healthy: true without checking" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:healthy]).to be true
      end
    end

    context "when connection is refused" do
      it "raises a retryable ApplicationError" do
        allow(Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("ProxyUnhealthy")
          expect(error.non_retryable).to be false
        }
      end
    end

    context "when agent run does not exist" do
      it "raises ActiveRecord::RecordNotFound" do
        expect {
          activity.execute(agent_run_id: -1)
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when proxy URL is invalid" do
      around do |example|
        original_paid_proxy_url = ENV["PAID_PROXY_URL"]
        ENV["PAID_PROXY_URL"] = "not a valid url"
        example.run
      ensure
        ENV["PAID_PROXY_URL"] = original_paid_proxy_url
      end

      it "raises a non-retryable ProxyConfigurationError" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("ProxyConfigurationError")
          expect(error.non_retryable).to be true
        }
      end
    end

    context "when proxy URL has an unsupported scheme" do
      around do |example|
        original_paid_proxy_url = ENV["PAID_PROXY_URL"]
        ENV["PAID_PROXY_URL"] = "ftp://localhost:3000"
        example.run
      ensure
        ENV["PAID_PROXY_URL"] = original_paid_proxy_url
      end

      it "raises a non-retryable ProxyConfigurationError" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("ProxyConfigurationError")
          expect(error.non_retryable).to be true
        }
      end
    end
  end

  private

  def stub_health_check(status_code)
    response = instance_double(Net::HTTPResponse, code: status_code.to_s)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:get).and_return(response)
  end
end
