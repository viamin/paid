# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    # Shared host-pattern validation for tenant-managed egress allowlist
    # entries (RDR-055). One source of truth for both the model validation
    # (write-time) and the resolver's defensive re-validation (read-time), so
    # a legacy or manually-inserted row can never widen a run's egress policy.
    #
    # Supported shapes: exact public hostnames (+api.example.com+) and
    # leading-wildcard subdomains (+*.packages.example.com+). Rejected: bare
    # or mid-host wildcards, wildcard TLDs, URL paths/userinfo/ports, IP
    # literals (including private, loopback, link-local, and metadata IPs),
    # and localhost names.
    # @spec EGRESS-POLICY-001
    module HostPattern
      MAX_HOST_LENGTH = 253
      LABEL_REGEX = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
      TLD_REGEX = /\A[a-z]{2}[a-z0-9-]*[a-z0-9]\z/
      RESERVED_TLDS = %w[local test example invalid].freeze
      IPV4_SHAPE_REGEX = /\A\d{1,3}(\.\d{1,3}){3}\z/
      WILDCARD_PREFIX = "*."

      module_function

      # @param pattern [Object] candidate host pattern
      # @return [String, nil] rejection reason, or nil when the pattern is safe
      def invalid_reason(pattern)
        return "is missing" if pattern.nil?
        return "must be a string" unless pattern.is_a?(String)
        return "is blank" if pattern.strip.empty?

        value = pattern.strip.downcase
        return "is longer than #{MAX_HOST_LENGTH} characters" if value.length > MAX_HOST_LENGTH
        return "contains characters not allowed in a hostname" if value.match?(/[^a-z0-9.*-]/)
        return "must not be a bare wildcard" if value == "*"

        host = strip_leading_wildcard(value)
        return reason_for_nested_wildcard(host) if host.include?("*")
        return "must not be an IP literal" if ip_literal?(host)
        return "must not target localhost" if localhost?(host)
        return "must have at least two host labels" unless host.count(".") >= 1

        labels = host.split(".")
        return "has an invalid label (empty, or starting/ending with '-')" unless labels.all? { |label| LABEL_REGEX.match?(label) }
        return "top-level domain must not be a reserved or special-use TLD" if RESERVED_TLDS.include?(labels.last)
        return "top-level domain must be at least two alphabetic characters" unless TLD_REGEX.match?(labels.last)

        nil
      end

      # True when +host+ matches +pattern+ (exact or leading-wildcard
      # subdomain). Caller validates the pattern; an invalid pattern never
      # matches, keeping matching fail-closed.
      def matches?(pattern, host)
        return false if pattern.blank? || host.blank?

        normalized_pattern = pattern.to_s.strip.downcase
        normalized_host = host.to_s.strip.downcase
        if normalized_pattern.start_with?(WILDCARD_PREFIX)
          suffix = normalized_pattern.delete_prefix(WILDCARD_PREFIX)
          normalized_host.end_with?(".#{suffix}")
        else
          normalized_host == normalized_pattern
        end
      end

      def strip_leading_wildcard(value)
        return value unless value.start_with?(WILDCARD_PREFIX)

        value.delete_prefix(WILDCARD_PREFIX)
      end

      def reason_for_nested_wildcard(host)
        return "wildcard must be a single leading label" if host.start_with?(WILDCARD_PREFIX) || host == "*"

        "wildcard is only allowed as the leading label"
      end

      def ip_literal?(host)
        IPV4_SHAPE_REGEX.match?(host)
      end

      def localhost?(host)
        host == "localhost" || host == "localhost.localdomain" ||
          host.end_with?(".localhost", ".localhost.localdomain")
      end
    end
  end
end
