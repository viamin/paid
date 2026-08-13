# frozen_string_literal: true

# Base module for PromptAssembly section providers. Each provider is a callable
# object that receives a {PromptAssembly::Context} and returns a
# {PromptAssembly::Section}.
#
# Subclasses implement {#build_section} to produce the section content. When
# the content is blank the section is emitted as an excluded section so the
# assembler records it as provenance (with a skip reason) and drops its text.
module PromptAssembly
  module Sections
    module Base
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def call(context)
          new(context).call
        end
      end

      attr_reader :context

      def initialize(context)
        @context = context
      end

      def call
        content = build_section.to_s.strip

        if content.empty?
          PromptAssembly::Section.new(
            key: section_key,
            source: section_source,
            content: "",
            trust_level: :excluded,
            exclusion_reason: skip_reason || "empty"
          )
        else
          PromptAssembly::Section.new(
            key: section_key,
            source: section_source,
            content: content,
            trust_level: trust_level,
            required: required,
            inclusion_reason: inclusion_reason
          )
        end
      end

      # @return [Symbol] identifier for this section
      def section_key
        self.class.name.demodulize.underscore.to_sym
      end

      # @return [Symbol] provenance source for this section (defaults to the key)
      def section_source
        section_key
      end

      # @return [Symbol] trust classification for this section's content
      def trust_level
        :trusted
      end

      # @return [Boolean] whether the section is safety-critical (never suppressed)
      def required
        false
      end

      # @return [String, nil] why the section was included
      def inclusion_reason
        nil
      end

      # @return [String, nil] reason when the section is empty (override for context)
      def skip_reason
        nil
      end

      private

      def issue
        context.issue
      end

      def project
        context.project
      end

      def github_client
        context.github_client
      end

      def agent_run
        context.agent_run
      end

      def issue_comments
        context.issue_comments
      end

      # Subclasses implement this to produce section content.
      def build_section
        raise NotImplementedError
      end
    end
  end
end
