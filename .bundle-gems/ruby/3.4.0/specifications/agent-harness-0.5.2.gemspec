# -*- encoding: utf-8 -*-
# stub: agent-harness 0.5.2 ruby lib

Gem::Specification.new do |s|
  s.name = "agent-harness".freeze
  s.version = "0.5.2".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "changelog_uri" => "https://github.com/viamin/agent-harness/blob/main/CHANGELOG.md", "homepage_uri" => "https://github.com/viamin/agent-harness", "rubygems_mfa_required" => "true", "source_code_uri" => "https://github.com/viamin/agent-harness" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Bart Agapinan".freeze]
  s.bindir = "exe".freeze
  s.date = "1980-01-02"
  s.description = "AgentHarness provides a unified interface for CLI-based AI coding agents like\nClaude Code, Cursor, Gemini CLI, and others. It offers full orchestration with\nprovider switching, circuit breakers, health monitoring, flexible configuration,\ndynamic provider registration, and token usage tracking.\n".freeze
  s.email = ["bart@sonic.net".freeze]
  s.homepage = "https://github.com/viamin/agent-harness".freeze
  s.licenses = ["MIT".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 3.2.0".freeze)
  s.rubygems_version = "4.0.6".freeze
  s.summary = "Unified interface for CLI-based AI coding agents".freeze

  s.installed_by_version = "3.6.9".freeze

  s.specification_version = 4

  s.add_development_dependency(%q<rake>.freeze, ["~> 13.0".freeze])
  s.add_development_dependency(%q<rspec>.freeze, ["~> 3.0".freeze])
  s.add_development_dependency(%q<standard>.freeze, ["~> 1.3".freeze])
end
