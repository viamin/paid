# frozen_string_literal: true

require "rails_helper"

RSpec.describe Paid::JsonLogFormatter, :no_db do # @spec OBSERVABILITY-004
  subject(:formatter) { described_class.new }

  it "renders structured log payloads as JSON lines" do
    line = formatter.call(
      "INFO",
      Time.utc(2026, 8, 5, 12, 30, 45, 123_000),
      nil,
      { message: "agent_execution.completed", agent_run_id: 42, status: "completed" }
    )

    expect(JSON.parse(line)).to eq(
      "timestamp" => "2026-08-05T12:30:45.123Z",
      "level" => "info",
      "message" => "agent_execution.completed",
      "agent_run_id" => 42,
      "status" => "completed"
    )
  end

  it "includes the current request id when present" do
    Current.request_id = "request-123"

    line = formatter.call("INFO", Time.utc(2026, 8, 5, 12, 30, 45), nil, { message: "web.request" })
    expect(JSON.parse(line)).to include(
      "message" => "web.request",
      "request_id" => "request-123"
    )
  ensure
    Current.reset
  end
end
