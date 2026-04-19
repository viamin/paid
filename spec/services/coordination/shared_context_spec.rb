# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::SharedContext do
  let(:workflow_id) { "ctx-workflow-#{SecureRandom.hex(4)}" }
  let(:project) { create(:project) }
  let(:run_a) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
  let(:run_b) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
  let(:target_run) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }

  describe ".call" do
    it "collects changed files from sibling runs" do
      create(:agent_coordination_signal, :files_changed, source_agent_run: run_a, parent_workflow_id: workflow_id,
        payload: { "files" => [ "a.rb", "b.rb" ] })
      create(:agent_coordination_signal, :files_changed, source_agent_run: run_b, parent_workflow_id: workflow_id,
        payload: { "files" => [ "c.rb" ] })

      result = described_class.call(agent_run: target_run)

      expect(result.changed_files).to contain_exactly("a.rb", "b.rb", "c.rb")
    end

    it "collects context entries visible to the run" do
      create(:agent_coordination_signal, :context_shared, source_agent_run: run_a, parent_workflow_id: workflow_id,
        payload: { "summary" => "Added User model" })

      result = described_class.call(agent_run: target_run)

      expect(result.context_entries.size).to eq(1)
      expect(result.context_entries.first[:payload]["summary"]).to eq("Added User model")
    end

    it "collects sequencing hints" do
      create(:agent_coordination_signal, :sequencing_hint, source_agent_run: run_a, parent_workflow_id: workflow_id,
        payload: { "hint" => "Run migrations first" })

      result = described_class.call(agent_run: target_run)

      expect(result.sequencing_hints.size).to eq(1)
      expect(result.sequencing_hints.first[:payload]["hint"]).to eq("Run migrations first")
    end

    it "returns empty results when run has no parent_workflow_id" do
      run = create(:agent_run, project: project, parent_workflow_id: nil)

      result = described_class.call(agent_run: run)

      expect(result.changed_files).to be_empty
      expect(result.context_entries).to be_empty
      expect(result.sequencing_hints).to be_empty
      expect(result.any_context?).to be false
    end

    it "reports any_context? when signals exist" do
      create(:agent_coordination_signal, :files_changed, source_agent_run: run_a, parent_workflow_id: workflow_id,
        payload: { "files" => [ "a.rb" ] })

      result = described_class.call(agent_run: target_run)

      expect(result.any_context?).to be true
    end
  end
end
