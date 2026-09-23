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

          # [facet, declared_in, the context whose scope resolves it]
          entries = policy.facets_for(path).map { |name, declared_in| [ name, declared_in, ctx ] }
          # v0.78.1: a parent's READ view includes its descendants' claims (v0.78),
          # so an agent at the parent meets facets a child declares (HSDL: the
          # thesis `significance` facet at `hsdl`) and asks what their terms mean.
          # List each descendant-declared facet too, resolved in THAT descendant's
          # scope and labelled by where it is declared. A leaf has no descendants —
          # byte-identical. Governance itself (Vocabulary.for) stays path-scoped.
          if ctx
            seen = entries.map(&:first)
            ctx.descendants.order(:id).each do |d|
              policy.facets_declared_in(d.key).each do |name|
                next if seen.include?(name)
                entries << [ name, d.key, d ]
                seen << name
              end
            end
          end
          entries = entries.select { |name, _, _| name == facet.to_s } if facet.present?
          raise ArgumentError, "unknown facet #{facet.inspect} in this scope" if entries.empty?

          {
            context: ctx&.key || "root",
            facets: entries.map { |name, declared_in, scope|
              scope_path = scope&.path_keys
              terms = Enliterator::Vocabulary.for(name, context: scope)
              {
                facet:       name,
                declared_in: declared_in,
                tier:        policy.tier_for(name, path: scope_path),
                required:    policy.required_terms(name, path: scope_path),
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
