# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec FACET-CONFIDENCE-013 @spec CONFIDENCE-DELIVERY-007
RSpec.describe PromptAssembly::Sections::AdmittedIntent do
  it "renders the immutable baseline with distinct evidence categories" do
    run = OpenStruct.new(external_metadata: {
      "admitted_intent" => {
        "design_baseline" => "a" * 40,
        "design_document_paths" => [ "docs/intent/example.md" ],
        "facets" => [
          {
            "name" => "Navigation",
            "intent_score" => 90,
            "technical_score" => 85,
            "expressed_intent" => [ "Keyboard first." ],
            "inferred_fit" => "The selected direction fits the issue.",
            "demonstrated_feasibility" => [ "Prototype passed." ]
          }
        ]
      }
    })
    context = PromptAssembly::Context.new(project: create(:project), agent_run: run)

    section = described_class.call(context)

    expect(section.content).to include("intent 90, technical 85")
    expect(section.content).to include("Admitted design revision: #{'a' * 40}")
    expect(section.content).to include("docs/intent/example.md")
    expect(section.content).to include("Expressed intent: Keyboard first.")
    expect(section.content).to include("Inferred fit: The selected direction fits the issue.")
    expect(section.content).to include("Demonstrated feasibility: Prototype passed.")
  end
end
