# frozen_string_literal: true

require "rails_helper"
require "temporalio/converters/failure_converter"
require "paid/temporal_data_converter"

RSpec.describe Workflows::AgentExecutionWorkflow do
  let(:workflow) { described_class.new }

  before do
    allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    allow(workflow).to receive(:run_activity).and_return(healthy: true)
  end

  def timed_out_activity(type:, started_event_id: 0, observed_unhealthy: false, application_type: nil)
    application_type ||= "ProxyUnhealthy" if observed_unhealthy
    cause = if application_type
      Temporalio::Api::Failure::V1::Failure.new(message: "test attempt failed",
        application_failure_info: Temporalio::Api::Failure::V1::ApplicationFailureInfo.new(type: application_type))
    end
    timeout = Temporalio::Api::Failure::V1::Failure.new(message: "test timeout", cause:,
      timeout_failure_info: Temporalio::Api::Failure::V1::TimeoutFailureInfo.new(timeout_type: type))
    failure = Temporalio::Api::Failure::V1::Failure.new(message: "test activity", cause: timeout,
      activity_failure_info: Temporalio::Api::Failure::V1::ActivityFailureInfo.new(
        scheduled_event_id: 1, started_event_id:, identity: "",
        activity_type: Temporalio::Api::Common::V1::ActivityType.new(name: "CheckProxyHealth"),
        activity_id: "1", retry_state: Temporalio::Error::RetryState::TIMEOUT
      ))
    Temporalio::Converters::FailureConverter.default.from_failure(failure, Paid::TemporalDataConverter.new)
  end

  # @spec TEMPORAL-ORCHESTRATION-014
  it "routes a new health check to existing control capacity with unchanged bounds" do
    workflow.send(:ensure_proxy_healthy, 42)

    expect(workflow).to have_received(:run_activity).with(Activities::CheckProxyHealthActivity,
      { agent_run_id: 42 }, start_to_close_timeout: 30, schedule_to_close_timeout: 600,
      retry_policy: described_class::PROXY_HEALTH_RETRY_POLICY, task_queue: Paid.poll_task_queue)
  end

  # @spec TEMPORAL-ORCHESTRATION-014
  it "preserves queue and timeout behavior for an unpatched history" do
    allow(Temporalio::Workflow).to receive(:patched).with("proxy-health-control-routing-v1").and_return(false)
    workflow.send(:ensure_proxy_healthy, 42)

    expect(workflow).to have_received(:run_activity).with(Activities::CheckProxyHealthActivity,
      { agent_run_id: 42 }, start_to_close_timeout: 30, schedule_to_close_timeout: 600,
      retry_policy: described_class::PROXY_HEALTH_RETRY_POLICY)
    failure = timed_out_activity(type: Temporalio::Error::TimeoutError::TimeoutType::SCHEDULE_TO_START)
    allow(workflow).to receive(:run_activity).and_raise(failure)

    expect { workflow.send(:ensure_proxy_healthy, 42) }
      .to raise_error(Temporalio::Error::ApplicationError) { |error| expect(error.type).to eq("ProxyUnavailable") }
  end

  [
    [ :SCHEDULE_TO_START, 0, false, "ProxyHealthSchedulingUnavailable" ],
    [ :START_TO_CLOSE, 2, false, "ProxyHealthExecutionTimedOut" ],
    [ :SCHEDULE_TO_CLOSE, 0, false, "ProxyHealthRecoveryExhausted" ],
    [ :SCHEDULE_TO_CLOSE, 2, false, "ProxyHealthRecoveryExhausted" ],
    [ :SCHEDULE_TO_CLOSE, 0, true, "ProxyHealthUnhealthy" ]
  ].each do |timeout_type, started_event_id, observed_unhealthy, expected_type|
    # @spec TEMPORAL-ORCHESTRATION-014
    it "classifies #{timeout_type}/#{started_event_id}/#{observed_unhealthy} without discarding completed work" do
      failure = timed_out_activity(type: Temporalio::Error::TimeoutError::TimeoutType.const_get(timeout_type),
        started_event_id:, observed_unhealthy:)
      allow(workflow).to receive(:run_activity).and_raise(failure)

      expect { workflow.send(:ensure_proxy_healthy, 42) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error.type).to eq(expected_type)
          expect(error.non_retryable).to be(true)
          expect(workflow.send(:should_retain_container?, true, error)).to be(true)
          expect(workflow.send(:should_retain_container?, false, error)).to be(false)
        end
    end
  end

  # @spec TEMPORAL-ORCHESTRATION-014
  it "does not infer no worker execution from a zero final start ID after an earlier infrastructure failure" do
    failure = timed_out_activity(type: Temporalio::Error::TimeoutError::TimeoutType::SCHEDULE_TO_CLOSE,
      application_type: "ActiveRecord::ConnectionTimeoutError")
    allow(workflow).to receive(:run_activity).and_raise(failure)

    expect { workflow.send(:ensure_proxy_healthy, 42) }
      .to raise_error(Temporalio::Error::ApplicationError) { |error| expect(error.type).to eq("ProxyHealthRecoveryExhausted") }
  end

  # @spec TEMPORAL-ORCHESTRATION-014
  it "leaves configuration failures on their existing path" do
    failure = Temporalio::Error::ApplicationError.new("invalid configuration", type: "ProxyConfigurationError", non_retryable: true)
    allow(workflow).to receive(:run_activity).and_raise(failure)

    expect { workflow.send(:ensure_proxy_healthy, 42) }.to raise_error(failure)
  end

  # @spec TEMPORAL-ORCHESTRATION-014
  it "propagates cancellation and never retains a cancelled execution" do
    failure = Temporalio::Error::CanceledError.new("cancelled")
    allow(workflow).to receive(:run_activity).and_raise(failure)

    expect { workflow.send(:ensure_proxy_healthy, 42) }.to raise_error(failure)
    expect(workflow.send(:should_retain_container?, true, failure)).to be(false)
  end
end
