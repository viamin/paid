# frozen_string_literal: true

module FeatureIntents
  # Session-backed store for unsaved decision-response drafts, keyed by
  # feature intent and decision so partial progress survives the redirected
  # render, refreshes, and navigation. A flash value would be consumed by the
  # first render and lost afterward. Only the draft of a successfully saved
  # decision is cleared; unrelated drafts stay intact.
  # @spec FACET-CONFIDENCE-019
  class ResponseDrafts
    SESSION_KEY = :feature_decision_drafts
    # Cookie sessions cap at 4KB: keep a handful of recent drafts and bound
    # each answer so draft storage cannot overflow the session cookie.
    MAX_DRAFTS = 4
    MAX_ANSWER_CHARS = 500

    def self.for_feature_intent(session, feature_intent)
      all(session)[feature_intent.id.to_s] || {}
    end

    def self.save(session, feature_intent:, decision_id:, answer:)
      feature_key = feature_intent.id.to_s
      answer = answer.to_s
      raise ArgumentError, "Response draft exceeds #{MAX_ANSWER_CHARS} characters." if answer.length > MAX_ANSWER_CHARS

      bucket = for_feature_intent(session, feature_intent).merge(decision_id.to_s => answer)
      write(session, all(session).except(feature_key).merge(feature_key => bucket))
    end

    def self.clear(session, feature_intent:, decision_id:)
      feature_key = feature_intent.id.to_s
      bucket = for_feature_intent(session, feature_intent).except(decision_id.to_s)
      kept = all(session).except(feature_key)
      kept[feature_key] = bucket if bucket.any?
      write(session, kept)
    end

    def self.all(session)
      session[SESSION_KEY] || {}
    end
    private_class_method :all

    def self.write(session, drafts)
      session[SESSION_KEY] = newest_first(drafts)
    end
    private_class_method :write

    def self.newest_first(drafts)
      triples = drafts.flat_map { |feature_key, bucket| bucket.map { |decision_key, answer| [ feature_key, decision_key, answer ] } }
      triples.last(MAX_DRAFTS).each_with_object({}) do |(feature_key, decision_key, answer), kept|
        (kept[feature_key] ||= {})[decision_key] = answer
      end
    end
    private_class_method :newest_first
  end
end
