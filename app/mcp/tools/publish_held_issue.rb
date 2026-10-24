# frozen_string_literal: true

module Tools
  # Chat surface for publishing coherent-but-not-ready work of a
  # confidence-driven feature as a planning-held GitHub issue. Speculative
  # alternatives are recorded on the feature in Paid and never filed as
  # GitHub issues.
  # @spec CONFIDENCE-DELIVERY-002
  class PublishHeldIssue < BaseTool
    authorize :approve?, ->(args) { feature_intent_for(args.fetch(:feature_intent_id)) }, policy_class: FeatureIntentPolicy

    def self.tool_name = "publish_held_issue"
    def self.write_operation? = true

    def self.description
      "Publish one coherent task of a confidence-driven feature as a planning-held GitHub issue with explicit " \
        "parent and dependency links. Speculative alternatives stay in Paid; pass them to record them without filing issues."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          feature_intent_id: { type: "integer", description: "The confidence-driven feature intent ID" },
          title: { type: "string", description: "Coherent task title" },
          body: { type: "string", description: "Coherent task purpose and scope", default: "" },
          parent_issue_number: { type: "integer", description: "GitHub number of the feature's umbrella issue to link as parent" },
          depends_on_issue_numbers: {
            type: "array",
            items: { type: "integer" },
            description: "GitHub numbers of prerequisite issues in the same repository"
          },
          facet_prerequisites: {
            type: "array",
            description: "Material prerequisite facets for the published scope",
            items: {
              type: "object",
              properties: {
                facet_id: { type: "integer" },
                direction_id: { type: "integer" },
                rationale: { type: "string" }
              },
              required: %w[facet_id]
            }
          },
          speculative_alternatives: {
            type: "array",
            description: "Speculative alternatives to keep visible in Paid without GitHub issues",
            items: {
              type: "object",
              properties: { title: { type: "string" }, summary: { type: "string" } },
              required: %w[title]
            }
          },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[feature_intent_id title confirmed]
      }
    end

    # @spec CONFIDENCE-DELIVERY-002
    def perform(feature_intent_id:, title:, confirmed: false, body: "", parent_issue_number: nil,
      depends_on_issue_numbers: [], facet_prerequisites: [], speculative_alternatives: [])
      raise ArgumentError, "Confirmation required: set confirmed=true to publish a held issue" unless confirmed

      feature_intent = feature_intent_for(feature_intent_id)
      unless feature_intent.confidence_driven?
        raise ArgumentError, "Only confidence-driven features publish planning-held issues"
      end

      result = FeatureIntents::PublishHeldIssue.call(
        feature_intent: feature_intent,
        title: title,
        body: body,
        parent_issue: parent_issue_for(feature_intent, parent_issue_number),
        dependencies: dependency_issues_for(feature_intent, depends_on_issue_numbers),
        facet_prerequisites: facet_entries_for(feature_intent, facet_prerequisites),
        speculative_alternatives: speculative_alternatives
      )

      audit_publication(feature_intent, result)

      {
        number: result.issue.github_number,
        url: result.issue.github_html_url,
        feature_intent_issue_id: result.link.id,
        reused: result.reused?,
        speculative_alternatives_recorded: result.speculative_alternatives.length
      }
    end

    private

    def feature_intent_for(id)
      @feature_intents_by_id ||= {}
      @feature_intents_by_id[id] ||= FeatureIntentPolicy::Scope.new(user, FeatureIntent).resolve.find(id)
    end

    def parent_issue_for(feature_intent, number)
      return if number.blank?

      issue_by_number(feature_intent, number, "parent")
    end

    def dependency_issues_for(feature_intent, numbers)
      Array(numbers).map { |number| issue_by_number(feature_intent, number, "dependency") }
    end

    def issue_by_number(feature_intent, number, role)
      feature_intent.project.issues.find_by(github_number: number).tap do |issue|
        raise ArgumentError, "Unknown #{role} issue number #{number} in #{feature_intent.project.full_name}" unless issue
      end
    end

    def facet_entries_for(feature_intent, entries)
      Array(entries).filter_map do |entry|
        attributes = entry.to_h.transform_keys(&:to_s)
        facet = feature_intent.facets.find_by(id: attributes.fetch("facet_id", nil))
        raise ArgumentError, "Facet #{attributes['facet_id']} does not belong to feature #{feature_intent.id}" if facet.blank?

        {
          facet: facet,
          direction: facet.directions.find_by(id: attributes["direction_id"]),
          rationale: attributes["rationale"]
        }
      end
    end

    def audit_publication(feature_intent, result)
      # Reuses the `issue.created` audit category — the tool's durable write is
      # a created GitHub issue; publication specifics live in metadata and the
      # service's structured log.
      Audit::RecordEvent.call(
        action: "issue.created",
        actor: user,
        subject: feature_intent.project,
        metadata: {
          issue_number: result.issue.github_number,
          planning_held: true,
          feature_intent_id: feature_intent.id,
          reused: result.reused?,
          speculative_alternatives_recorded: result.speculative_alternatives.length
        }
      )
    end
  end
end
