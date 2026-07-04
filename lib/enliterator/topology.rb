# frozen_string_literal: true

module Enliterator
  # The collection's declared TOPOLOGY — the part-whole structure a host tells the
  # engine about, instead of the engine assuming the flat corpus.
  #
  #   Enliterator.configure do |c|
  #     c.topology = Enliterator::Topology.new do
  #       whole "Manuscript", members: "Chapter", foreign_key: :manuscript_id,
  #             context_key: :slug, context_name: :title
  #     end
  #   end
  #
  # A `whole` declaration names the host GROUPING that composes member records into
  # a whole (a book made of chapters): the whole's type name, the member type name,
  # the member's foreign key to the whole, and the whole's methods supplying the
  # derived Context's key and display name. From it the engine derives two things —
  # a Context per whole (Topology::Sync; membership = the whole's HOLDINGS, every
  # member by foreign key, drafts included) and, when `config.default_reading_scope`
  # is :whole, a grouping-direct tend-time neighbor scope (the FK subquery itself,
  # never the derived membership, so the tend path cannot be starved by a stale or
  # missing sync).
  #
  # HONEST SCOPE: this class is the grouping/membership half of the topology
  # declaration described in "The Shape of a Collection" §5. Ordering (the sequence
  # axis) is deliberately NOT declared here yet — it lands with its consumer
  # (order-aware reading, roadmap item 4); declaring fields nothing reads would be
  # fantasy state. The `whole` DSL is keyword-extensible for that day.
  #
  # LOAD-INDEPENDENCE (the v0.55 lesson): declarations hold TYPE NAMES as strings,
  # set at boot from the initializer. Classes are constantized lazily at use sites
  # (sync, the visitor), where the app is fully loaded. Never memoize constants at
  # class level — configuration is reset per spec example.
  #
  # Topology does NOT imply `synthesized_tendables`: a whole that is also a Tendable
  # must still be masked explicitly (Sync warns when it isn't), and a synthesized
  # tendable with no grouping (the future collection/charter record) is no whole.
  class Topology
    # One declared grouping. All names are strings/symbols — no class references.
    Whole = Struct.new(:whole_type, :member_type, :foreign_key,
                       :context_key, :context_name, keyword_init: true) do
      def whole_class  = whole_type.constantize
      def member_class = member_type.constantize
    end

    def initialize(&block)
      @wholes = []
      instance_eval(&block) if block
      @wholes.freeze
    end

    # DSL: declare a grouping. One declaration per MEMBER type (this slice scopes a
    # member's reading by "its whole" — two wholes claiming the same member type
    # would make that ambiguous), enforced loudly at declaration time.
    def whole(whole_type, members:, foreign_key:, context_key:, context_name:)
      whole_type = whole_type.to_s
      members    = members.to_s
      if @wholes.any? { |w| w.member_type == members }
        raise Enliterator::ConfigurationError,
              "Topology already declares a whole for member type #{members.inspect} — " \
              "one whole per member type (a member's reading scope must be unambiguous)"
      end
      @wholes << Whole.new(whole_type: whole_type, member_type: members,
                           foreign_key: foreign_key.to_sym,
                           context_key: context_key.to_sym,
                           context_name: context_name.to_sym).freeze
      self
    end

    def wholes = @wholes

    def declares_wholes? = @wholes.any?

    # The declaration whose members are the given type name, or nil. The visitor's
    # per-tend lookup — an in-memory scan of a tiny frozen list, zero queries.
    def declaration_for_member(type_name)
      @wholes.find { |w| w.member_type == type_name.to_s }
    end

    def declaration_for_whole(type_name)
      @wholes.find { |w| w.whole_type == type_name.to_s }
    end
  end
end
