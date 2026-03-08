# -*- encoding: utf-8 -*-
# stub: qdrant-ruby 0.9.10 ruby lib

Gem::Specification.new do |s|
  s.name = "qdrant-ruby".freeze
  s.version = "0.9.10".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "changelog_uri" => "https://github.com/andreibondarev/qdrant-ruby/CHANGELOG.md", "homepage_uri" => "https://github.com/andreibondarev/qdrant-ruby", "source_code_uri" => "https://github.com/andreibondarev/qdrant-ruby" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Andrei Bondarev".freeze]
  s.bindir = "exe".freeze
  s.date = "1980-01-02"
  s.description = "Ruby wrapper for the Qdrant vector search database API".freeze
  s.email = ["andrei@sourcelabs.io".freeze, "andrei.bondarev13@gmail.com".freeze]
  s.homepage = "https://github.com/andreibondarev/qdrant-ruby".freeze
  s.licenses = ["Apache-2.0".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.6.0".freeze)
  s.rubygems_version = "3.6.9".freeze
  s.summary = "Ruby wrapper for the Qdrant vector search database API".freeze

  s.installed_by_version = "3.6.9".freeze

  s.specification_version = 4

  s.add_runtime_dependency(%q<faraday>.freeze, [">= 2.0.1".freeze, "< 3".freeze])
  s.add_development_dependency(%q<pry-byebug>.freeze, ["~> 3.9".freeze])
end
