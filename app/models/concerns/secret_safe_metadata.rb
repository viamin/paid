# frozen_string_literal: true

# Shared secret-safety guarantee for models that store free-form JSONB
# telemetry/audit metadata. Rejects metadata containing secret-shaped keys
# or values at validation time so telemetry/audit tables can never
# accidentally capture credential material, regardless of what a caller
# passes in.
#
# Extracted from RunnerAuthAttempt (RDR-041) so ExecutionAuditEvent
# (RDR-061) does not reimplement the same secret-pattern scan.
#
# Include this concern and wire `enforce_metadata_secret_safety` from a
# `before_validation`/`validate` callback in the host model; it operates on
# the host's `metadata` jsonb column.
module SecretSafeMetadata
  extend ActiveSupport::Concern

  # Reserved metadata keys that callers are forbidden from passing because
  # they could leak credentials. Keep this list narrow and explicit so
  # future callers fail fast rather than silently storing secret-shaped
  # data.
  FORBIDDEN_METADATA_KEYS = %w[
    token
    refresh_token
    access_token
    api_key
    authorization_code
    auth_code
    code
    client_secret
    secret
    bearer
    password
    passwd
    pwd
    cookie
    session
    credentials
    credential
    native_credentials
    native_credential
    native_credentials_json
    native_credential_json
    auth_json
    credentials_json
  ].freeze

  # Patterns that look like secret material. If a metadata value matches one
  # of these (after trimming), the recorder raises rather than persisting
  # the row. GitHub token formats mirror GithubToken::GITHUB_TOKEN_PATTERN so
  # a `github_pat_` fine-grained PAT is rejected with the same shape the
  # rest of the app uses to recognize them (classic `ghp_`, fine-grained
  # `github_pat_`, OAuth `gho_`, user-to-server `ghu_`, server-to-server
  # `ghs_`, refresh `ghr_`).
  SECRET_VALUE_PATTERNS = [
    /\Ask-[A-Za-z0-9_-]{8,}\z/,                # Anthropic / OpenAI style bearer tokens
    /\A(ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|gh[ours]_[A-Za-z0-9]{36,})\z/, # GitHub PATs
    /\Axox[abprs]-[A-Za-z0-9-]{8,}\z/,         # Slack tokens
    /\Aya29\.[A-Za-z0-9_-]{8,}\z/,             # Google OAuth bearer
    /\ABearer\s+/i,                            # Authorization header prefix
    /\ABasic\s+[A-Za-z0-9+\/=]{8,}\z/i         # HTTP Basic auth header
  ].freeze

  class_methods do
    # Returns true if `value` looks like a secret that must never be
    # persisted in telemetry/audit metadata. Exposed so callers (and tests)
    # can preflight metadata before passing it in. Expects a scalar;
    # structured values are walked recursively by `scan_metadata_for_secrets`
    # before this is called, so treating a Hash/Array as "secret-like" would
    # mask scalars nested inside.
    def secret_like?(value)
      return false if value.nil?

      text = value.to_s
      return false if text.empty?

      SECRET_VALUE_PATTERNS.any? { |pattern| text.match?(pattern) }
    end
  end

  private

  def metadata_is_object
    errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
  end

  def enforce_metadata_secret_safety
    scan_metadata_for_secrets(metadata)
  end

  def strip_unknown_metadata
    return unless metadata.is_a?(Hash)

    self.metadata = stringify_metadata(metadata)
  end

  # Recursively walks a jsonb node at every key level so secret-shaped values
  # nested inside Hashes/Arrays are caught at validation time. Iterates in
  # two phases: every key is checked against the forbidden list, and every
  # leaf scalar value is checked against the secret patterns. The keys
  # themselves are matched as strings so symbol keys (the common caller
  # convention) get the same treatment as string keys. `attribute` lets
  # callers scan columns other than `metadata` (e.g. ExecutionAuditEvent's
  # `network_policy`) while attaching errors to the right field.
  def scan_metadata_for_secrets(node, path: [], attribute: :metadata)
    case node
    when Hash
      node.each do |key, value|
        child_path = path + [ key.to_s ]
        if FORBIDDEN_METADATA_KEYS.include?(key.to_s)
          errors.add(attribute, "contains forbidden key #{child_path.join('.')}")
        end
        scan_metadata_for_secrets(value, path: child_path, attribute: attribute)
      end
    when Array
      node.each_with_index do |element, index|
        scan_metadata_for_secrets(element, path: path + [ index.to_s ], attribute: attribute)
      end
    else
      if self.class.secret_like?(node)
        errors.add(attribute, "contains a secret-shaped value at key #{path.join('.')}")
      end
    end
  end

  # Recursively stringifies metadata keys, preserving the original
  # Hash/Array shape so nested structures round-trip unchanged. Mirrors
  # `scan_metadata_for_secrets` so the two passes never disagree about what
  # counts as a leaf.
  def stringify_metadata(node)
    case node
    when Hash
      node.each_with_object({}) do |(key, value), memo|
        memo[key.to_s] = stringify_metadata(value)
      end
    when Array
      node.map { |element| stringify_metadata(element) }
    else
      node
    end
  end
end
