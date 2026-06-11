module Enliterator
  module Mcp
    module Tools
      # The collection's claim language: facets (the dimensions records are
      # read along) and their controlled vocabularies — code terms plus
      # curator-approved extensions, with required terms and scheduling
      # marked. Speak THESE keys when discussing claims; propose_term when
      # the language is missing a word.
      class Vocabulary < Tool
        name_and_description "vocabulary",
          "The controlled vocabulary: every facet with its tier and term meanings " \
          "(or one facet in detail). Claims use exactly these keys — read this before " \
          "interpreting or citing claims."

        schema({
          "facet"   => str("Optional facet name for full detail"),
          "context" => str("Optional context key (facets and approvals are context-scoped)")
        })

        def call(facet: nil, context: nil)
          ctx    = resolve_context(context)
          path   = ctx&.path_keys
          policy = Enliterator.staffing

          facets = policy.facets_for(path)
          facets = facets.select { |f, _| f == facet.to_s } if facet.present?
          raise ArgumentError, "unknown facet #{facet.inspect} in this scope" if facets.empty?

          {
            context: ctx&.key || "root",
            facets: facets.map { |name, declared_in|
              terms = Enliterator::Vocabulary.for(name, context: ctx)
              {
                facet:       name,
                declared_in: declared_in,
                tier:        policy.tier_for(name, path: path),
                required:    policy.required_terms(name, path: path),
                scheduled:   policy.scheduled?(name, declared_in == "root" ? nil : declared_in),
                terms:       terms # nil = unconstrained (open facet)
              }.compact
            },
            next: { propose_term: "file a vocabulary suggestion through authority control",
                    human_view: "/enliterator/settings" }
          }
        end
      end
    end
  end
end
