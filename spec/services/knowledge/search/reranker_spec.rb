# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Search::Reranker do
  describe "#call" do
    let(:base_result) do
      {
        chunk_id: "chunk-1",
        artifact_type: "route",
        identifier: "POST /api/users",
        content: "some content",
        score: 0.5,
        source: "hybrid",
        project_version: { commit_sha: "abc123", committed_at: "2026-03-01T12:00:00Z" },
        scope_tags: [],
        status: "active",
        link_count: 0,
        created_at: Time.current
      }
    end

    it "boosts results matching the target commit SHA" do
      results = described_class.call(results: [ base_result ], target_sha: "abc123")

      expect(results.first[:score]).to be > 0.5
    end

    it "does not boost when SHA does not match" do
      result_with_no_match = base_result.merge(
        project_version: { commit_sha: "other_sha" }
      )

      results = described_class.call(results: [ result_with_no_match ], target_sha: "abc123")

      # Still gets active boost but not version boost
      expect(results.first[:score]).to be < base_result[:score] + 0.15
    end

    it "boosts active results" do
      active = base_result.merge(status: "active", score: 0.5)
      stale = base_result.merge(chunk_id: "chunk-2", status: "stale", score: 0.5)

      results = described_class.call(results: [ stale, active ])

      expect(results.first[:chunk_id]).to eq("chunk-1")
    end

    it "boosts results with more links" do
      no_links = base_result.merge(link_count: 0, score: 0.5)
      with_links = base_result.merge(chunk_id: "chunk-2", link_count: 3, score: 0.5)

      results = described_class.call(results: [ no_links, with_links ])

      linked_result = results.find { |r| r[:chunk_id] == "chunk-2" }
      unlinked_result = results.find { |r| r[:chunk_id] == "chunk-1" }

      expect(linked_result[:score]).to be > unlinked_result[:score]
    end

    it "caps link boost at 3 links" do
      three_links = base_result.merge(chunk_id: "chunk-2", link_count: 3, score: 0.5)
      ten_links = base_result.merge(chunk_id: "chunk-3", link_count: 10, score: 0.5)

      results = described_class.call(results: [ three_links, ten_links ])

      r3 = results.find { |r| r[:chunk_id] == "chunk-2" }
      r10 = results.find { |r| r[:chunk_id] == "chunk-3" }

      expect(r3[:score]).to eq(r10[:score])
    end

    it "penalizes older results" do
      recent = base_result.merge(created_at: Time.current, score: 0.5)
      old = base_result.merge(chunk_id: "chunk-2", created_at: 10.days.ago, score: 0.5)

      results = described_class.call(results: [ old, recent ])

      recent_result = results.find { |r| r[:chunk_id] == "chunk-1" }
      old_result = results.find { |r| r[:chunk_id] == "chunk-2" }

      expect(recent_result[:score]).to be > old_result[:score]
    end

    it "sorts results by score descending" do
      low = base_result.merge(chunk_id: "chunk-1", score: 0.2, status: "stale")
      high = base_result.merge(chunk_id: "chunk-2", score: 0.9)

      results = described_class.call(results: [ low, high ])

      expect(results.first[:chunk_id]).to eq("chunk-2")
    end

    it "handles nil target_sha gracefully" do
      results = described_class.call(results: [ base_result ], target_sha: nil)

      expect(results.size).to eq(1)
    end
  end
end
