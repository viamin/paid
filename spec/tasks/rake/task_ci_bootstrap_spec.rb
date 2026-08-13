# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe Rake::Task, :no_db do
  let(:task_name) { "ci:bootstrap_test_defaults" }
  let(:task) { described_class[task_name] }

  before do
    Rails.application.load_tasks unless described_class.task_defined?(task_name)
    task.reenable
    allow(TenantContext).to receive(:with_system_access).and_yield
    allow(OrchestrationStrategies::Seed).to receive(:call)
    allow(Strategies::SeedBaselineOrchestration).to receive(:call)
  end

  it "seeds the orchestration defaults that schema-only test databases do not include" do
    task.invoke

    expect(TenantContext).to have_received(:with_system_access)
    expect(OrchestrationStrategies::Seed).to have_received(:call)
    expect(Strategies::SeedBaselineOrchestration).to have_received(:call)
  end
end
