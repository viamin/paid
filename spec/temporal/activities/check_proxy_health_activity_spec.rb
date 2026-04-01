# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckProxyHealthActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  before do
    stub_const("ENV", ENV.to_h.merge("PAID_PROXY_URL" => "http://localhost:3000"))
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
      it "returns healthy: true immediately" do
        stub_health_check(200)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:healthy]).to be true
      end
    end

    context "when proxy is initially unhealthy then recovers" do
      it "waits and retries until healthy" do
        allow(activity).to receive(:sleep)
        allow(activity).to receive(:heartbeat)

        stub_health_check_sequence([ 503, 503, 200 ])

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:healthy]).to be true
        expect(result[:waited_seconds]).to be >= 0
      end
    end

    context "when proxy never recovers" do
      it "raises ProxyUnavailable after MAX_WAIT_SECONDS" do
        allow(activity).to receive(:sleep)
        allow(activity).to receive(:heartbeat)
        stub_health_check(503)

        # Stub MAX_WAIT_SECONDS to a small value for test speed
        stub_const("Activities::CheckProxyHealthActivity::MAX_WAIT_SECONDS", 10)
        stub_const("Activities::CheckProxyHealthActivity::INITIAL_POLL_INTERVAL", 5)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("ProxyUnavailable")
        }
      end
    end

    context "when PAID_PROXY_URL is not set" do
      before do
        stub_const("ENV", ENV.to_h.except("PAID_PROXY_URL"))
        allow(Rails.application.config.x).to receive(:proxy_url).and_return(nil)
      end

      it "returns healthy: true without checking" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:healthy]).to be true
      end
    end

    context "when connection is refused" do
      it "treats connection errors as unhealthy" do
        allow(activity).to receive(:sleep)
        allow(activity).to receive(:heartbeat)
        allow(Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)

        stub_const("Activities::CheckProxyHealthActivity::MAX_WAIT_SECONDS", 5)
        stub_const("Activities::CheckProxyHealthActivity::INITIAL_POLL_INTERVAL", 5)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("ProxyUnavailable")
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

  def stub_health_check_sequence(status_codes)
    responses = status_codes.map { |code| instance_double(Net::HTTPResponse, code: code.to_s) }
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:get).and_return(*responses)
  end
end
