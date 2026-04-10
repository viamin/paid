# -*- encoding: utf-8 -*-
# stub: ruby-maat 1.2.0 ruby lib

Gem::Specification.new do |s|
  s.name = "ruby-maat".freeze
  s.version = "1.2.0".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "allowed_push_host" => "https://rubygems.org", "changelog_uri" => "https://github.com/viamin/ruby-maat/blob/main/CHANGELOG.md", "homepage_uri" => "https://github.com/viamin/ruby-maat", "rubygems_mfa_required" => "true", "source_code_uri" => "https://github.com/viamin/ruby-maat" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Adam Tornhill".freeze, "Claude Code".freeze, "Bart Agapinan".freeze]
  s.bindir = "exe".freeze
  s.date = "2025-08-17"
  s.description = "Ruby Maat is a command line tool used to mine and analyze data from version-control systems (VCS). This is a Ruby port of the original Clojure Code Maat.".freeze
  s.email = ["bart@sonic.net".freeze]
  s.executables = ["ruby-maat".freeze]
  s.files = ["exe/ruby-maat".freeze]
  s.homepage = "https://github.com/viamin/ruby-maat".freeze
  s.licenses = ["GPL-3.0".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 3.2.0".freeze)
  s.rubygems_version = "3.6.2".freeze
  s.summary = "A command line tool used to mine and analyze data from version-control systems".freeze

  s.installed_by_version = "3.6.9".freeze

  s.specification_version = 4

  s.add_runtime_dependency(%q<csv>.freeze, ["~> 3.2".freeze])
  s.add_runtime_dependency(%q<rexml>.freeze, ["~> 3.2".freeze])
  s.add_runtime_dependency(%q<rover-df>.freeze, ["~> 0.3".freeze])
end
