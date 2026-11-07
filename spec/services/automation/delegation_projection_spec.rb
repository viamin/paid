# frozen_string_literal: true

module Automation
  RSpec.describe DelegationProjection do
    # @spec PROJECT-DELEGATION-005
    describe "shared delegation projection" do
      let(:project) { create(:project, auto_pick_enabled: true, auto_merge_enabled: false) }

      describe "#phase_authorized?" do
          it "returns true when EffectivePolicy permits the phase" do
            projection = described_class.call(project:, phase: Automation::Phases::DISCOVERY)
            expect(projection.phase_authorized?(Automation::Phases::DISCOVERY)).to be true
          end

          it "returns false when EffectivePolicy denies the phase" do
            # Disable coding phase
            project.update!(
              automation_phase_settings: {
                "phases" => { Automation::Phases::CODING => false }
              }
            )
            projection = described_class.call(project:)
            expect(projection.phase_authorized?(Automation::Phases::CODING)).to be false
          end
      end

      describe "convenience phase methods" do
          it "provides discovery_authorized? method" do
            projection = described_class.call(project:)
            expect(projection.discovery_authorized?).to be true
          end

          it "provides issue_preparation_authorized? method" do
            projection = described_class.call(project:)
            expect(projection.issue_preparation_authorized?).to be true
          end

          it "provides coding_authorized? method" do
            projection = described_class.call(project:)
            expect(projection.coding_authorized?).to be true
          end

          it "provides merge_authorized? method" do
            projection = described_class.call(project:)
            expect(projection.merge_authorized?).to be true
          end

          it "provides release_deployment_authorized? method" do
            projection = described_class.call(project:)
            expect(projection.release_deployment_authorized?).to be true
          end

          it "provides operations_authorized? method" do
            projection = described_class.call(project:)
            expect(projection.operations_authorized?).to be false # Not enabled by default
          end
      end

      describe "#authorized_phases" do
          it "returns all phases currently authorized" do
            projection = described_class.call(project:)
            phases = projection.authorized_phases
            expect(phases).to include(Automation::Phases::DISCOVERY)
            expect(phases).to include(Automation::Phases::CODING)
            expect(phases).to include(Automation::Phases::MERGE)
            expect(phases).not_to include(Automation::Phases::OPERATIONS)
          end
      end

      describe "#effective_policy" do
          it "returns the underlying EffectivePolicy decision" do
            projection = described_class.call(project:)
            policy = projection.effective_policy(Automation::Phases::CODING)
            expect(policy).to be_a(Automation::EffectivePolicy::Decision)
            expect(policy.permitted?).to be true
          end
      end

      describe "#to_h serialization" do
          it "includes project_id" do
            projection = described_class.call(project:)
            expect(projection.to_h[:project_id]).to eq(project.id)
          end

          it "includes authorized_phases" do
            projection = described_class.call(project:)
            expect(projection.to_h[:authorized_phases]).to be_an(Array)
          end

          it "includes phase_decisions with details" do
            projection = described_class.call(project:)
            decisions = projection.to_h[:phase_decisions]
            expect(decisions).to be_a(Hash)
            Automation::Phases::ALL.each do |phase|
              expect(decisions[phase]).to include(:permitted, :source, :reason, :phase)
            end
          end
      end

      describe "with work_item parameter" do
          let(:issue) { create(:issue, project:) }

          it "passes work_item to EffectivePolicy" do
            projection = described_class.call(project:, work_item: issue)
            # EffectivePolicy accepts work_item for continuation grant evaluation
            expect(projection.phase_authorized?(Automation::Phases::DISCOVERY)).to be true
          end
      end

      describe "with trigger parameter" do
          it "defaults to :automatic trigger" do
            projection = described_class.call(project:)
            policy = projection.effective_policy(Automation::Phases::CODING)
            # Automatic trigger should have different behavior than manual
            expect(policy).not_to be_nil
          end

          it "respects manual trigger" do
            # Disable the phase
            project.update!(
              automation_phase_settings: {
                "phases" => { Automation::Phases::CODING => false }
              }
            )
            # Manual actions bypass phase settings
            projection = described_class.call(project:, trigger: :manual)
            policy = projection.effective_policy(Automation::Phases::CODING)
            expect(policy.permitted?).to be true # Manual overrides disabled phase
          end
        end
      end
    end
end
