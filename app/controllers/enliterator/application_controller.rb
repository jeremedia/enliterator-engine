module Enliterator
  class ApplicationController < ActionController::Base
    # v0.13: every surface is viewed THROUGH a context (a nested enliterated
    # collection). `?context=<key>` selects one (persisted in a cookie, mirroring
    # the host's one-shot-param-then-cookie pattern); no selection or
    # `?context=root` ⇒ the root view — the unfiltered union of the whole
    # collection (root rule), which is exactly the pre-v0.13 behavior.
    helper_method :current_context, :context_switcher_options

    private

    CONTEXT_COOKIE = :enliterator_context

    def current_context
      return @current_context if defined?(@current_context)
      @current_context = resolve_context
    end

    def resolve_context
      key = params[:context].presence || cookies[CONTEXT_COOKIE].presence
      return clear_context! if key.blank? || key == "root"

      ctx = Enliterator::Context.find_by(key: key)
      if ctx.nil?
        # A stale cookie or typo'd param must not 500 a surface — fall back to
        # root and say why.
        Enliterator.logger&.warn("[enliterator] unknown context #{key.inspect} — falling back to root")
        return clear_context!
      end
      cookies[CONTEXT_COOKIE] = ctx.key
      ctx
    end

    def clear_context!
      cookies.delete(CONTEXT_COOKIE)
      nil
    end

    # The layout switcher's options: every context, depth-indented, in tree
    # order. Empty when no tree is seeded — which hides the switcher entirely,
    # so flat installs see no UI change.
    def context_switcher_options
      @context_switcher_options ||= Enliterator::Context.roots.order(:name).flat_map { |root|
        root.subtree.arrange_serializable.then { |arranged| flatten_arranged(arranged) }
      }
    end

    # [["HSDL", "hsdl", 0], ["— CRS Reports", "crs-reports", 1], ...]
    def flatten_arranged(nodes, depth = 0)
      Array(nodes).flat_map do |node|
        label = "#{'— ' * depth}#{node['name']}".strip
        [ [ label, node["key"] ] ] + flatten_arranged(node["children"], depth + 1)
      end
    end
  end
end
