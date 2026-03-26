# frozen_string_literal: true

require "ipaddr"

module Paid
  module TailscaleHosts
    HOSTNAME_PATTERN = /\A[a-z0-9-]+\.ts\.net(?::\d+)?\z/
    CGNAT_RANGE = IPAddr.new("100.64.0.0/10")
    FALSE_VALUES = %w[0 false off no].freeze

    module_function

    def enabled?
      value = ENV["ALLOW_TAILSCALE_HOSTS"]
      return true if value.nil?

      !FALSE_VALUES.include?(value.strip.downcase)
    end
  end
end
