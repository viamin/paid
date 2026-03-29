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
end
