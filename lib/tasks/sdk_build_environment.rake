# frozen_string_literal: true

require "json"

namespace :sdk_build_environment do
  desc "Classify the isolated Rust/SDK build environment on a Paid Docker backend (issue #5358). " \
       "Metadata-only probes in a disposable hardened container; no build, publication, or pin change. " \
       "SDK_BUILD_PREFLIGHT_IMAGE selects the image (default: the digest-pinned development toolchain); " \
       "SDK_BUILD_PREFLIGHT_BACKEND selects the backend by identifier (default: the active backend)."
  # @spec RUST-SDK-BUILD-011
  task preflight: :environment do
    image = ENV["SDK_BUILD_PREFLIGHT_IMAGE"].presence || SdkBuildEnvironments::Pins.default_image_reference
    identifier = ENV["SDK_BUILD_PREFLIGHT_BACKEND"].presence
    backend = identifier && Containers.all_backends.find { |candidate| candidate.identifier == identifier }
    abort("No backend with identifier #{identifier.inspect}") if identifier && backend.nil?

    facts = SdkBuildEnvironments::MetadataProbe.call(backend: backend || Containers.backend, image: image)
    receipt = SdkBuildEnvironments::Preflight.call(facts: facts)
    puts JSON.pretty_generate(receipt)
    abort("sdk build environment preflight verdict: #{receipt[:verdict]}") unless receipt[:verdict] == :compatible
  end
end
