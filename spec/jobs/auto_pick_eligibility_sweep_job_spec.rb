# frozen_string_literal: true

require "rails_helper"

RSpec.describe AutoPickEligibilitySweepJob, :no_db do
  def stub_projects(*projects)
    active_relation = instance_double(ActiveRecord::Relation)
    where_relation = instance_double(ActiveRecord::Relation)
    includes_relation = instance_double(ActiveRecord::Relation)
    select_relation = instance_double(ActiveRecord::Relation)

    allow(Project).to receive(:active).and_return(active_relation)
    allow(active_relation).to receive(:where).with(auto_pick_enabled: true).and_return(where_relation)
    allow(where_relation).to receive(:includes).with(:account).and_return(includes_relation)
    allow(includes_relation).to receive(:select).with(:id, :account_id, :created_by_id).and_return(select_relation)
    allow(select_relation).to receive(:to_a).and_return(projects)
    allow(includes_relation).to receive(:find_each) do |&block|
      projects.each { |p| block.call(p) }
    end
  end

  before do
    stub_const("Project", Class.new do
      attr_reader :id, :account_id, :created_by_id

      def initialize(id)
        @id = id
        @account_id = nil
        @created_by_id = nil
      end

      def self.active; end
      def self.where(*); end
    end)

    allow(Account).to receive(:batch_fallback_owner_ids).and_return({})
    user_relation = instance_double(ActiveRecord::Relation)
    allow(User).to receive(:where).and_return(user_relation)
    allow(user_relation).to receive(:index_by).and_return({})
  end

  it "bulk enqueues eligible issues for each runnable project" do
    project = Project.new(101)

    stub_projects(project)
    allow(Issues::AutoPickProjectGate).to receive(:call).with(project, hash_including(:owner)).and_return(true)
    allow(Issues::BulkEnqueueEligible).to receive(:call).and_return([])

    described_class.perform_now

    expect(Issues::BulkEnqueueEligible).to have_received(:call).with(
      project: project,
      skip_project_gate: true
    )
  end

  it "skips projects that do not pass the gate" do
    project = Project.new(202)

    stub_projects(project)
    allow(Issues::AutoPickProjectGate).to receive(:call).with(project, hash_including(:owner)).and_return(false)
    allow(Issues::BulkEnqueueEligible).to receive(:call)

    described_class.perform_now

    expect(Issues::BulkEnqueueEligible).not_to have_received(:call)
  end

  it "continues processing remaining projects after a failure" do
    failing_project = Project.new(303)
    healthy_project = Project.new(404)

    stub_projects(failing_project, healthy_project)
    allow(Issues::AutoPickProjectGate).to receive(:call).and_return(true)
    allow(Issues::BulkEnqueueEligible).to receive(:call) do |kwargs|
      raise "queue unavailable" if kwargs[:project].id == 303

      []
    end

    described_class.perform_now

    expect(Issues::BulkEnqueueEligible).to have_received(:call).twice
  end

  it "runs on every invocation unlike the one-time backfill" do
    project = Project.new(505)

    stub_projects(project)
    allow(Issues::AutoPickProjectGate).to receive(:call).with(project, hash_including(:owner)).and_return(true)
    allow(Issues::BulkEnqueueEligible).to receive(:call).and_return([])

    described_class.perform_now
    described_class.perform_now

    expect(Issues::BulkEnqueueEligible).to have_received(:call).twice.with(
      project: project,
      skip_project_gate: true
    )
  end
end
