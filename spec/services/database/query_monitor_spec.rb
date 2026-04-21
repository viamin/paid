# frozen_string_literal: true

require "rails_helper"

RSpec.describe Database::QueryMonitor do
  let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }

  around do |example|
    original_threshold = ENV["DATABASE_SLOW_QUERY_MS"]
    example.run
  ensure
    original_threshold ? ENV["DATABASE_SLOW_QUERY_MS"] = original_threshold : ENV.delete("DATABASE_SLOW_QUERY_MS")
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
  end

  it "logs slow queries" do
    monitor = described_class.new(label: "request", metadata: { path: "/dashboard" })

    monitor.record(name: "User Load", sql: "SELECT * FROM users WHERE id = 1", duration: 300.4)

    expect(logger).to have_received(:warn).with(
      hash_including(
        message: "database.query.slow",
        query_context: "request",
        duration_ms: 300.4,
        path: "/dashboard"
      )
    )
  end

  it "logs repeated select fingerprints when the context finishes" do
    monitor = described_class.new(label: "request", metadata: { path: "/agent_runs" })

    5.times do |id|
      monitor.record(name: "Issue Load", sql: "SELECT * FROM issues WHERE id = #{id}", duration: 2.0)
    end
    monitor.flush

    expect(logger).to have_received(:warn).with(
      hash_including(
        message: "database.query.repeated_select",
        query_context: "request",
        query_count: 5,
        total_duration_ms: 10.0,
        path: "/agent_runs"
      )
    )
  end

  it "wraps instrumentation in a thread-local monitor" do
    observed = nil

    described_class.instrument("job", job_class: "ExampleJob") do
      observed = described_class.current
    end

    expect(observed).to be_a(described_class)
    expect(described_class.current).to be_nil
  end

  it "records notification duration from sql event timings" do
    ENV["DATABASE_SLOW_QUERY_MS"] = "250"

    described_class.install!
    described_class.instrument("request", path: "/dashboard") do
      publish_sql_notification(duration: 0.3)
    end

    expect(logger).to have_received(:warn).with(
      hash_including(
        message: "database.query.slow",
        duration_ms: 300.0,
        path: "/dashboard"
      )
    )
  end

  def publish_sql_notification(duration:)
    started = Time.current
    ActiveSupport::Notifications.publish(
      "sql.active_record",
      started,
      started + duration,
      "query-id",
      name: "User Load",
      sql: "SELECT * FROM users"
    )
  end
end
