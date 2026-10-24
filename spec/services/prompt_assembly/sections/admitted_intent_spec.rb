# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec FACET-CONFIDENCE-013 @spec CONFIDENCE-DELIVERY-007
RSpec.describe PromptAssembly::Sections::AdmittedIntent do
  def section_for(admitted_intent)
    run = OpenStruct.new(external_metadata: { "admitted_intent" => admitted_intent })
    context = PromptAssembly::Context.new(project: create(:project), agent_run: run)
    described_class.call(context).content
  end

  def scored_facet
    {
      "name" => "Navigation",
      "direction" => "Keyboard navigation",
      "intent_score" => 90,
      "technical_score" => 85,
      "expressed_intent" => [ "Keyboard first." ],
      "inferred_fit" => "The selected direction fits the issue.",
      "demonstrated_feasibility" => [ "Prototype passed." ]
    }
  end

  it "renders the immutable baseline with distinct evidence categories" do
    content = section_for(
      "design_baseline" => "a" * 40,
      "design_document_paths" => [ "docs/intent/example.md" ],
      "facets" => [ scored_facet ]
    )

    expect(content).to include("Navigation (Keyboard navigation): intent 90, technical 85")
    expect(content).to include("Admitted design revision: #{'a' * 40}")
    expect(content).to include("docs/intent/example.md")
    expect(content).to include("Expressed intent: Keyboard first.")
    expect(content).to include("Inferred fit: The selected direction fits the issue.")
    expect(content).to include("Demonstrated feasibility: Prototype passed.")
  end

  it "labels per-direction entries so candidate scores stay distinguishable" do
    content = section_for(
      "facets" => [
        { "name" => "Navigation", "direction" => "Keyboard navigation", "intent_score" => 92, "technical_score" => 84 },
        { "name" => "Navigation", "direction" => "Pointer support", "intent_score" => 71, "technical_score" => 90 },
        { "name" => "Persistence" }
      ]
    )

    expect(content).to include("- Navigation (Keyboard navigation): intent 92, technical 84")
    expect(content).to include("- Navigation (Pointer support): intent 71, technical 90")
    expect(content).to include("- Persistence: intent unknown, technical unknown")
  end
end
