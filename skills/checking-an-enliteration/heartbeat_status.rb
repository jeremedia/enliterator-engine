# Read-only health snapshot of a running enliteration. Run from the HOST app dir.
# Production host (systemd/SSH don't auto-load env): source it inline first —
#   set -a; source ~/.<app>-rails.env; set +a
#   bin/rails runner <engine>/skills/checking-an-enliteration/heartbeat_status.rb
# Development host (dotenv loads .env): no sourcing — just set the mode —
#   RAILS_ENV=development bin/rails runner <engine>/skills/.../heartbeat_status.rb
# Touches nothing. Engine schema only, so it works on any deployment.

hb = Enliterator::Heartbeat

puts "=== LAST 8 BEATS (the ledger IS the authority — not the launchd log) ==="
hb.order(id: :desc).limit(8).each do |h|
  ex   = h.executed.is_a?(Hash) ? h.executed : {}
  succ = ex.sum { |_, v| v.is_a?(Hash) ? v["succeeded"].to_i : 0 }
  defr = ex.sum { |_, v| v.is_a?(Hash) ? v["deferred"].to_i  : 0 }
  fail = ex.sum { |_, v| v.is_a?(Hash) ? v["failed"].to_i    : 0 }
  tok  = h.tokens_spent.is_a?(Hash) ? h.tokens_spent["total"] : nil
  con  = h.considerer.is_a?(Hash) ? h.considerer.sum { |_, v| v.is_a?(Hash) ? v["considered"].to_i : 0 } : nil
  aud  = h.audits.is_a?(Hash) ? h.audits["examined"] : nil
  dur  = (h.finished_at && h.started_at) ? (h.finished_at - h.started_at).round : nil
  puts "id=#{h.id} #{h.started_at&.strftime('%m-%d %H:%M')} dur=#{dur}s " \
       "succeeded=#{succ} deferred=#{defr} failed=#{fail} tokens=#{tok || '—'} " \
       "considered=#{con} audited=#{aud} warn=#{h.warnings.to_a.size} " \
       "ERR=#{h.error.present? ? h.error.to_s[0, 60] : 'nil'}"
end
# READ IT: error=nil + failed=0 = clean. deferred>0 & tokens=0 & error=nil = GRACEFUL
# DEFERRAL (a model/auth provider was down at beat time) — NOT a failure; it drains
# next beat. considered/audited present = the governance tier (often the only paid/
# expiring one) was reachable that night.

puts "\n=== VISITS BY DAY (14d) — is real work landing? ==="
Enliterator::Visit.where("created_at > ?", 14.days.ago)
  .group("DATE(created_at)").count.sort.each { |d, c| puts "  #{d}: #{c}" }
# READ IT: a drop to a low, FLAT plateau usually means a drained frontier — small
# nightly beats are the correct steady state, NOT a stall. Big daytime spikes are
# usually a separate continuous deep-read worker, not the pacemaker.

puts "\n=== FAILED VISITS (7d): pacemaker vs. a separate worker ==="
# A failed visit is one with a non-null error (engine schema; no boolean success col).
f = Enliterator::Visit.where.not(error: nil).where("created_at > ?", 7.days.ago)
puts "  total failed: #{f.count}"
puts "  with heartbeat_id (pacemaker): #{f.where.not(heartbeat_id: nil).count}"
puts "  heartbeat_id NULL (a deep-read / continuous worker): #{f.where(heartbeat_id: nil).count}"
# READ IT: heartbeat_id=nil failures are NOT the pacemaker. A continuous deep-read
# worker sheds per-part casualties during transient provider windows and RETRIES them;
# record-level work still completes. Check THAT worker's own log before calling it broken.

puts "\n=== CLAIMS (the durable output) ==="
puts "  live: #{Enliterator::Claim.live.count rescue Enliterator::Claim.count}"
puts "  created 7d: #{Enliterator::Claim.where('created_at > ?', 7.days.ago).count}"
