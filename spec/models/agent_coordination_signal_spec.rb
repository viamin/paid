# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentCoordinationSignal do
  describe "associations" do
    it { is_expected.to belong_to(:source_agent_run).class_name("AgentRun") }
    it { is_expected.to belong_to(:target_agent_run).class_name("AgentRun").optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:parent_workflow_id) }
    it { is_expected.to validate_length_of(:parent_workflow_id).is_at_most(255) }
    it { is_expected.to validate_presence_of(:signal_type) }
    it { is_expected.to validate_inclusion_of(:signal_type).in_array(described_class::SIGNAL_TYPES) }
  end

  describe "scopes" do
    let(:workflow_id) { "test-workflow-#{SecureRandom.hex(4)}" }
    let(:project) { create(:project) }
    let(:run_a) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
    let(:run_b) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }

    describe ".for_workflow" do
      it "returns signals matching the workflow id" do
        signal = create(:agent_coordination_signal, source_agent_run: run_a, parent_workflow_id: workflow_id)
        create(:agent_coordination_signal, source_agent_run: run_a, parent_workflow_id: "other-workflow")

        expect(described_class.for_workflow(workflow_id)).to contain_exactly(signal)
      end
    end

    describe ".by_type" do
      it "filters by signal type" do
        files_signal = create(:agent_coordination_signal, :files_changed, source_agent_run: run_a, parent_workflow_id: workflow_id)
        create(:agent_coordination_signal, :dependency_completed, source_agent_run: run_a, parent_workflow_id: workflow_id)

        expect(described_class.by_type("files_changed")).to contain_exactly(files_signal)
      end
    end

    describe ".visible_to" do
      it "includes broadcast signals and targeted signals" do
        broadcast = create(:agent_coordination_signal, source_agent_run: run_a, parent_workflow_id: workflow_id, target_agent_run: nil)
        targeted = create(:agent_coordination_signal, source_agent_run: run_a, parent_workflow_id: workflow_id, target_agent_run: run_b)
        create(:agent_coordination_signal, source_agent_run: run_a, parent_workflow_id: workflow_id,
          target_agent_run: create(:agent_run, project: project, parent_workflow_id: workflow_id))

        expect(described_class.visible_to(run_b)).to contain_exactly(broadcast, targeted)
      end
    end
  end

  describe ".changed_files_for_workflow" do
    it "aggregates files from all files_changed signals" do
      workflow_id = "test-wf-#{SecureRandom.hex(4)}"
      project = create(:project)
      run_a = create(:agent_run, project: project, parent_workflow_id: workflow_id)
      run_b = create(:agent_run, project: project, parent_workflow_id: workflow_id)

      create(:agent_coordination_signal, source_agent_run: run_a, parent_workflow_id: workflow_id,
        signal_type: "files_changed", payload: { "files" => [ "a.rb", "b.rb" ] })
      create(:agent_coordination_signal, source_agent_run: run_b, parent_workflow_id: workflow_id,
        signal_type: "files_changed", payload: { "files" => [ "b.rb", "c.rb" ] })

      files = described_class.changed_files_for_workflow(workflow_id)
      expect(files).to contain_exactly("a.rb", "b.rb", "c.rb")
    end
  end

  describe ".dependencies_met?" do
    let(:workflow_id) { "dep-wf-#{SecureRandom.hex(4)}" }
    let(:project) { create(:project) }
    let(:run_a) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
    let(:run_b) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
    let(:run_c) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }

    it "returns true when all required runs have sent dependency_completed" do
      create(:agent_coordination_signal, :dependency_completed, source_agent_run: run_a, parent_workflow_id: workflow_id)
      create(:agent_coordination_signal, :dependency_completed, source_agent_run: run_b, parent_workflow_id: workflow_id)

      expect(described_class.dependencies_met?(run_c, required_run_ids: [ run_a.id, run_b.id ])).to be true
    end

    it "returns false when some required runs have not completed" do
      create(:agent_coordination_signal, :dependency_completed, source_agent_run: run_a, parent_workflow_id: workflow_id)

      expect(described_class.dependencies_met?(run_c, required_run_ids: [ run_a.id, run_b.id ])).to be false
    end

    it "returns true for empty required_run_ids" do
      expect(described_class.dependencies_met?(run_c, required_run_ids: [])).to be true
    end
  end

  describe ".any_dependency_failed?" do
    let(:workflow_id) { "fail-wf-#{SecureRandom.hex(4)}" }
    let(:project) { create(:project) }
    let(:run_a) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
    let(:run_b) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }

    it "returns true when a required run sent dependency_failed" do
      create(:agent_coordination_signal, :dependency_failed, source_agent_run: run_a, parent_workflow_id: workflow_id)

      expect(described_class.any_dependency_failed?(run_b, required_run_ids: [ run_a.id ])).to be true
    end

    it "returns false when no failure signals exist" do
      expect(described_class.any_dependency_failed?(run_b, required_run_ids: [ run_a.id ])).to be false
    end
  end
end
