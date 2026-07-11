module Enliterator
  module FirstImpression
    # Pure metric aggregation — no LLM, no DB. Turns per-run judgments into the
    # diagnostic's headline: how much the enliteration adds over the bare surrogate,
    # per arm (and per arm x tier), with spread across the sampled records.
    #
    # A Run is one (record, arm, tier, rep) after judging. `golden` maps question id
    # to {"type"=>, "deep"=>bool}; `confidences` maps id to the model's stated 0..1;
    # `verdicts` maps id to {"correct"=>0..1, "abstained"=>bool, "fabricated"=>bool}.
    module Report
      Run = Struct.new(:arm, :tier, :record, :golden, :confidences, :verdicts,
                       :fe_rich, :tokens, keyword_init: true)

      module_function

      def clamp(x)
        f = Float(x) rescue 0.5
        f.clamp(0.0, 1.0)
      end

      def mean(xs)
        xs = xs.compact
        xs.empty? ? nil : (xs.sum.to_f / xs.size).round(3)
      end

      def std(xs)
        xs = xs.compact
        return 0.0 if xs.size < 2
        m = xs.sum.to_f / xs.size
        Math.sqrt(xs.sum { |x| (x - m)**2 } / xs.size).round(3)
      end

      # The per-metric value of ONE run, averaged over that run's questions.
      def metrics_for_run(run)
        reading = []; coverage = []; deep = []; reliab = []; fab = []; brier = []
        run.golden.each do |id, g|
          vd  = run.verdicts[id] || { "correct" => 0.0 }
          cor = clamp(vd["correct"])
          conf = clamp(run.confidences[id] || 0.5)
          brier << (conf - cor)**2
          case g["type"]
          when "reading"     then reading << cor
          when "coverage"    then (coverage << cor; deep << cor if g["deep"])
          when "reliability" then reliab << cor
          end
          fab << (vd["fabricated"] ? 1.0 : 0.0) if %w[coverage trap].include?(g["type"])
        end
        { "reading" => mean(reading), "coverage" => mean(coverage), "deep" => mean(deep),
          "reliability" => mean(reliab), "fabrication" => mean(fab), "brier" => mean(brier),
          "fe_rich" => run.fe_rich, "tokens" => run.tokens }
      end

      METRICS = %w[reading coverage deep reliability fabrication brier fe_rich tokens].freeze

      # Aggregate runs into the report.
      def build(runs)
        scored = runs.map { |r| [ r, metrics_for_run(r) ] }

        per_arm_tier = {}
        group(scored) { |r| [ r.arm, r.tier ] }.each do |(arm, tier), rows|
          per_arm_tier["#{arm}|#{tier}"] = summarize(rows)
        end
        per_arm = {}
        group(scored) { |r| r.arm }.each { |arm, rows| per_arm[arm] = summarize(rows) }

        arms = runs.map(&:arm).uniq
        canary = arms.to_h { |a| [ a, per_arm.dig(a, "reading", 0) ] }

        {
          "n_records"    => runs.map(&:record).uniq.size,
          "arms"         => arms,
          "tiers"        => runs.map(&:tier).uniq,
          "per_arm"      => per_arm,
          "per_arm_tier" => per_arm_tier,
          "reading_canary" => canary,
          "headline"     => headline(per_arm)
        }
      end

      # rows: [[run, metrics], ...] sharing an arm (or arm+tier). Each metric ->
      # [mean, std] over the rows.
      def summarize(rows)
        METRICS.to_h do |m|
          vals = rows.map { |(_, mm)| mm[m] }.compact
          [ m, [ mean(vals), std(vals) ] ]
        end
      end

      def group(scored)
        scored.group_by { |(r, _)| yield(r) }.transform_values { |pairs| pairs }
      end

      # The one-line takeaways: the enliteration's coverage + reliability lift over
      # the bare surrogate.
      def headline(per_arm)
        man = ->(m) { per_arm.dig("manual", m, 0) }
        bare = ->(m) { per_arm.dig("no_map", m, 0) }
        {
          "coverage_manual"    => man.call("coverage"),
          "coverage_no_map"    => bare.call("coverage"),
          "coverage_lift"      => delta(man.call("coverage"), bare.call("coverage")),
          "reliability_manual" => man.call("reliability"),
          "reliability_no_map" => bare.call("reliability"),
          "reliability_lift"   => delta(man.call("reliability"), bare.call("reliability")),
          "reading_flat"       => reading_flat?(per_arm)
        }
      end

      def delta(a, b)
        return nil if a.nil? || b.nil?
        (a - b).round(3)
      end

      # The confound canary: reading accuracy should be ~equal across arms (facts
      # equally present). A spread > 0.15 means an answer leaked into the wrong arm.
      def reading_flat?(per_arm)
        vals = per_arm.values.map { |m| m.dig("reading", 0) }.compact
        return true if vals.size < 2
        (vals.max - vals.min) <= 0.15
      end
    end
  end
end
