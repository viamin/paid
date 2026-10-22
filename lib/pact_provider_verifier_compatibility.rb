# frozen_string_literal: true

# Pact provider verifier 1.x still invokes Rack 2's HeaderHash and JSON 2's
# three-argument load API. This file is preloaded only by the CI verifier
# process; it does not alter the Rails application process.
# @spec MOBILE-API-017
require "json"
require "rack"

module PactProviderVerifierCompatibility
  def self.install!
    install_header_hash!
    install_json_load!
  end

  def self.install_header_hash!
    return if Rack::Utils.const_defined?(:HeaderHash, false)

    rack_2_header_hash = Class.new(Rack::Headers) do
      def initialize(headers = {})
        super()
        headers.each { |name, value| self[name] = Array(value).join("\n") }
      end
    end

    Rack::Utils.const_set(:HeaderHash, rack_2_header_hash)
  end

  def self.install_json_load!
    return if JSON.singleton_class.method_defined?(:pact_provider_verifier_load)

    JSON.singleton_class.class_eval do
      alias_method :pact_provider_verifier_load, :load

      def load(source, proc = nil, options = nil)
        return pact_provider_verifier_load(source, proc) unless options

        raise ArgumentError, "JSON.load callback is unsupported with options" if proc

        parse(source, **options)
      end
    end
  end
end

PactProviderVerifierCompatibility.install!
