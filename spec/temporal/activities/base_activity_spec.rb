# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::BaseActivity do
  let(:activity_class) do
    Class.new(described_class) do
      def execute(input)
        input
      end
    end
  end
  let(:activity) do
    stub_const("TestBaseActivity", activity_class)
    TestBaseActivity.new
  end
  let(:connection_pool) { instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool) }
  let(:executor) { object_double(Rails.application.executor) }

  before do
    allow(ActiveRecord::Base).to receive(:connection_pool).and_return(connection_pool)
    allow(connection_pool).to receive(:active_connection?).and_return(true)
    allow(connection_pool).to receive(:release_connection)
    allow(Rails.application).to receive(:executor).and_return(executor)
    allow(executor).to receive(:wrap).and_yield
  end

  it "normalizes hash inputs, wraps execution in the executor, and releases the DB connection" do
    result = activity.execute("project_id" => 123)

    expect(result).to eq(project_id: 123)
    expect(executor).to have_received(:wrap)
    expect(connection_pool).to have_received(:release_connection)
  end

  it "skips release when no active connection is checked out" do
    allow(connection_pool).to receive(:active_connection?).and_return(false)

    result = activity.execute("project_id" => 456)

    expect(result).to eq(project_id: 456)
    expect(connection_pool).not_to have_received(:release_connection)
  end

  describe "#check_rate_budget!" do
    let(:client) { instance_double(GithubClient) }

    it "does nothing when rate limit is not low" do
      allow(client).to receive(:rate_limit_low?).and_return(false)

      expect { activity.send(:check_rate_budget!, client) }.not_to raise_error
    end

    it "raises a retryable ApplicationError when rate limit is low" do
      allow(client).to receive_messages(rate_limit_low?: true, rate_limit_remaining: 5)

      expect { activity.send(:check_rate_budget!, client) }.to raise_error(
        Temporalio::Error::ApplicationError, /rate limit budget low/i
      ) do |error|
        expect(error.type).to eq("RateLimit")
      end
    end
  end

  it "releases the DB connection even when execute raises" do
    error_activity_class = Class.new(described_class) do
      def execute(_input)
        raise RuntimeError, "activity failed"
      end
    end
    stub_const("ErrorActivity", error_activity_class)
    error_activity = ErrorActivity.new

    expect { error_activity.execute("project_id" => 789) }.to raise_error(RuntimeError, "activity failed")
    expect(executor).to have_received(:wrap)
    expect(connection_pool).to have_received(:release_connection)
  end
end
