# frozen_string_literal: true

require "digest"

module Activities
  # Computes deterministic idempotency keys for side-effecting Temporal
  # activities so that a retry (worker crash after the write but before
  # Temporal records completion) can detect and reuse the rows a previous
  # attempt already created instead of duplicating them.
  #
  # The key is derived from the *stable* portion of the activity input — the
  # pieces Temporal replays verbatim on retry (ids, candidate sets, mutation
  # payloads). Unstable values (timestamps, generated ids) must NOT be fed in.
  module IdempotencyKey
    module_function

    # Returns a 64-character hex digest for the given stable input parts.
    # Hashes and arrays are canonicalized (sorted keys) so semantically
    # identical inputs always produce the same key.
    def compute(*parts)
      Digest::SHA256.hexdigest(canonicalize(parts))
    end

    def canonicalize(parts)
      parts.map { |part| canonicalize_value(part) }.join("\x1f")
    end

    def canonicalize_value(value)
      case value
      when Hash
        "{" + value.map { |key, val| "#{canonicalize_value(key)}=#{canonicalize_value(val)}" }
                   .sort.join(",") + "}"
      when Array
        "[" + value.map { |val| canonicalize_value(val) }.join(",") + "]"
      when nil
        "\x00"
      else
        value.to_s
      end
    end
  end
end
