# -*- encoding: utf-8 -*-
# stub: temporalio 1.3.0 aarch64-linux lib

Gem::Specification.new do |s|
  s.name = "temporalio".freeze
  s.version = "1.3.0".freeze
  s.platform = "aarch64-linux".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "homepage_uri" => "https://github.com/temporalio/sdk-ruby", "rubygems_mfa_required" => "true", "source_code_uri" => "https://github.com/temporalio/sdk-ruby" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Temporal Technologies Inc".freeze]
  s.bindir = "exe".freeze
  s.date = "2026-02-18"
  s.email = ["sdk@temporal.io".freeze]
  s.homepage = "https://github.com/temporalio/sdk-ruby".freeze
  s.licenses = ["MIT".freeze]
  s.required_ruby_version = Gem::Requirement.new([">= 3.3".freeze, "< 4.1.dev".freeze])
  s.rubygems_version = "3.5.23".freeze
  s.summary = "Temporal.io Ruby SDK".freeze

  s.installed_by_version = "3.6.2".freeze

  s.specification_version = 4

  s.add_runtime_dependency(%q<google-protobuf>.freeze, [">= 3.25.0".freeze])
  s.add_runtime_dependency(%q<logger>.freeze, [">= 0".freeze])
end
