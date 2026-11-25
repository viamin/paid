# frozen_string_literal: true

require "digest"
require "json"

module ReviewThreads
  # Pins resolution authority to the exact GitHub thread content observed by
  # the semantic assessment. Field selection is explicit so hash key ordering
  # and unrelated client representation changes cannot alter the digest.
  # @spec FOCUSED-RUN-011
  class ContentDigest
    FORMAT = /\Asha256:[a-f0-9]{64}\z/

    def self.call(thread)
      payload = {
        id: thread[:id],
        is_resolved: thread[:is_resolved],
        comment_count: thread[:comment_count],
        comments: Array(thread[:comments]).map do |comment|
          comment.slice(:id, :body, :path, :line, :author, :created_at, :commit_id)
        end
      }
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    def self.valid?(digest) = digest.is_a?(String) && digest.match?(FORMAT)
  end
end
