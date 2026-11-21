# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  describe "observation replay" do
    let(:finding) { create(:layered_verification_finding) }
    let(:results) do
      create_list(:layered_verification_check_result, 2, obligation: finding.obligation, agent_run: finding.agent_run)
    end
    let(:attributes) do
      { obligation: finding.obligation, agent_run: finding.agent_run, check_result_ids: results.map(&:id),
        evidence: { observed_behavior: { "check_results" => results.map(&:id) } } }
    end

    it "retains one observation when the same result set is replayed in a different order" do
      finding.add_observation!(**attributes)
      first_observation = finding.reload.observations.sole

      finding.add_observation!(**attributes.merge(check_result_ids: results.reverse.map(&:id)))

      expect(finding.reload.observations).to eq([ first_observation ])
    end

    it "preserves a resolved finding and its retained evidence on replay" do
      finding.add_observation!(**attributes)
      finding.update!(status: "resolved")
      retained = finding.reload.attributes.slice("status", "observations", "observed_behavior", "updated_at")

      finding.add_observation!(**attributes)

      expect(finding.reload.attributes.slice(*retained.keys)).to eq(retained)
    end

    it "still reopens a resolved finding when a distinct check result arrives" do
      finding.add_observation!(**attributes)
      finding.update!(status: "resolved")
      new_result = create(:layered_verification_check_result, obligation: finding.obligation, agent_run: finding.agent_run)

      finding.add_observation!(**attributes.merge(check_result_ids: [ new_result.id ]))

      expect(finding.reload.status).to eq("open")
      expect(finding.observations.size).to eq(2)
      expect(finding.observations.last.fetch("check_result_ids")).to eq([ new_result.id ])
    end
  end

  # @spec LAYERED-VERIFY-017
  it "persists the obligation's stable external identity" do
    finding = create(:layered_verification_finding)

    expect(finding.obligation_external_identity).to eq(finding.obligation.external_identity)
  end

  # @spec LAYERED-VERIFY-015
  it "invalidates the Inbox count when it enters or leaves a counted status" do
    finding = build(:layered_verification_finding)
    account = finding.project.account

    expect(Dashboard::CacheVersion).to receive(:bump).with(account, scope: Dashboard::CacheVersion::INBOX_SCOPE).twice

    finding.save!
    finding.update!(status: "resolved")
  end
end
