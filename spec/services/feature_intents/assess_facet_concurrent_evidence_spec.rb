# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-012
RSpec.describe FeatureIntents::AssessFacet do
  self.use_transactional_tests = false

  let(:direction) { create(:feature_intent_facet_direction) }
  let(:facet) { direction.feature_intent_facet }
  let(:project) { facet.feature_intent.project }
  let(:account) { project.account }
  let(:assessment) do
    create(:feature_intent_facet_assessment, feature_intent_facet_direction: direction,
      evidence_revision: facet.evidence_revision, status: "pending")
  end
  let(:updated) { Queue.new }
  let(:commit_now) { Queue.new }
  let(:harness) { double(send_message: completed_response) }
  let(:completed_response) do
    double(success?: true, output: JSON.generate(
      "status" => "completed", "intent_score" => 90, "technical_score" => 75,
      "inferred_fit" => "The candidate fits the assessed scope.",
      "explanation" => "Assessed before the concurrent evidence landed.", "evidence_references" => []
    ))
  end

  after do
    FeatureIntentFacetAssessment.where(feature_intent_facet_direction_id: direction.id).destroy_all
    facet.feature_intent.destroy!
    project.destroy!
    account.destroy!
  end

  it "waits out an in-flight evidence transaction instead of completing against superseded evidence" do
    assessment

    ingest_thread = start_in_flight_ingest
    updated.pop

    assess_thread = start_assessment
    expect(assess_thread.join(5)).to be_nil # blocked on the facet row lock, not reading stale committed state

    commit_now << true
    raise "In-flight ingest timed out" unless ingest_thread.join(10)
    raise "Assessment timed out" unless assess_thread.join(10)

    expect(FeatureIntentFacetAssessment.find(assessment.id))
      .to have_attributes(status: "superseded", intent_score: nil, technical_score: nil)
  ensure
    commit_now << true
    [ ingest_thread, assess_thread ].compact.each do |thread|
      raise "Assessment thread did not terminate" unless thread.join(5)
    end
  end

  private

  def start_in_flight_ingest
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          FeatureIntentFacet.transaction do
            locked_facet = FeatureIntentFacet.lock.find(facet.id)
            locked_facet.update!(evidence_revision: locked_facet.evidence_revision + 1)
            updated << true
            commit_now.pop
          end
        end
      end
    end
  end

  def start_assessment
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          described_class.call(assessment: FeatureIntentFacetAssessment.find(assessment.id), agent_harness: harness)
        end
      end
    end
  end
end
