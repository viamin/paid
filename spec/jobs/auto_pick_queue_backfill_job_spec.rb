# frozen_string_literal: true

require "rails_helper"

RSpec.describe AutoPickQueueBackfillJob, :no_db do
  let(:project_class) do
    Class.new do
      attr_reader :id

      def initialize(id)
        @id = id
      end

      def self.where(*); end
    end
  end

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    stub_const("Project", project_class)
    example.run
  ensure
    Rails.cache = original_cache
  end

  it "bulk seeds already-enabled projects once" do
    project = instance_double(Project, id: 101)
    relation = instance_double(ActiveRecord::Relation)

    allow(Project).to receive(:where).with(auto_pick_enabled: true).and_return(relation)
    allow(relation).to receive(:find_each).and_yield(project)
    allow(relation).to receive(:pluck).with(:id).and_return([ project.id ])
    allow(Issues::BulkEnqueueEligible).to receive(:call)

    described_class.perform_now
    described_class.perform_now

    expect(Issues::BulkEnqueueEligible).to have_received(:call).once.with(
      project: project,
      skip_project_gate: true
    )
  end

  it "retries projects that failed in a previous pass" do
    project = instance_double(Project, id: 202)
    relation = instance_double(ActiveRecord::Relation)
    calls = 0

    allow(Project).to receive(:where).with(auto_pick_enabled: true).and_return(relation)
    allow(relation).to receive(:find_each).and_yield(project)
    allow(relation).to receive(:pluck).with(:id).and_return([ project.id ])
    allow(Issues::BulkEnqueueEligible).to receive(:call) do
      calls += 1
      raise "queue unavailable" if calls == 1
    end

    described_class.perform_now
    described_class.perform_now

    expect(Issues::BulkEnqueueEligible).to have_received(:call).twice.with(
      project: project,
      skip_project_gate: true
    )
  end
end
