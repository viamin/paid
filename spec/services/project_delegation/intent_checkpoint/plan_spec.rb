# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Plan do
  it "groups material questions with recommendation, alternatives, consequences, scope, evidence and revisions" do
    feature_intent = create(:feature_intent)
    questions = [ create(:feature_intent_decision, feature_intent:) ]

    result = described_class.call(
      feature_intent:, questions:, recommendation: "Use the narrow rollout.",
      alternatives: [ { label: "Broad rollout" } ], consequences: [ "Lower migration risk." ],
      affected_scope: { paths: [ "app/models" ] }, evidence: [ { source: "RDR-080" } ],
      design_revision: "design-7", acceptance_revision: "acceptance-3"
    )

    expect(result.checkpoint).to have_attributes(
      status: "open", recommendation: "Use the narrow rollout.",
      proposed_design_revision: "design-7", proposed_acceptance_revision: "acceptance-3"
    )
    expect(result.checkpoint.questions).to contain_exactly(questions.first)
    expect(result.checkpoint.alternatives).to eq([ { "label" => "Broad rollout" } ])
  end

  it "rejects a plan whose design or acceptance revision is blank" do
    feature_intent = create(:feature_intent)
    questions = [ create(:feature_intent_decision, feature_intent:) ]
    base = { feature_intent:, questions:, recommendation: "Use the narrow rollout.",
             alternatives: [], consequences: [], affected_scope: {}, evidence: [] }

    expect { described_class.call(**base, design_revision: nil, acceptance_revision: "acceptance-3") }
      .to raise_error(ArgumentError, /Checkpoint revisions must be present/)
    expect { described_class.call(**base, design_revision: "design-7", acceptance_revision: " ") }
      .to raise_error(ArgumentError, /Checkpoint revisions must be present/)

    expect(feature_intent.project_delegation_intent_checkpoints).to be_empty
  end
end
