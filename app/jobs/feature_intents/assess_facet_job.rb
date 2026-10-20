# frozen_string_literal: true

module FeatureIntents
  # @spec FACET-CONFIDENCE-002 FACET-CONFIDENCE-012 FACET-CONFIDENCE-014
  class AssessFacetJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(assessment_id)
      AssessFacet.call(assessment: FeatureIntentFacetAssessment.find(assessment_id))
    end

    private

    def tenant_account
      TenantContext.with_system_access { FeatureIntentFacetAssessment.find_by(id: arguments.first)&.account }
    end
  end
end
