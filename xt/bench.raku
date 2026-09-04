# Benchmark for the state-machine minifier core.
# Usage: raku -Ilib xt/bench.raku
use v6;
use JS::Minifier;

my $unit = q:to/JS/;
/*! app bundle v1.0 */
var utils = {
  clamp: function(x, lo, hi) { return Math.max(lo, Math.min(x, hi)); },
  pad:   function(n, w)     { var s = String(n); while (s.length < w) { s = "0" + s; } return s; }
};
function render(items) {
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var it = items[i];
    if (it.hidden) { continue; }
    out.push("<li class=\"" + (it.cls || "def") + "\">" + utils.pad(it.id, 4) + ": " + it.name + "</li>");
  }
  return out.join("\n");
}
if (typeof window !== "undefined") { window.Render = render; }
JS

my $in = $unit x 800;
say "big blob: { $in.chars } chars";

my @bench = (
  { label => 'plain', args => {} },
  { label => 'aggr',  args => { :aggressive } },
);

for @bench -> $b {
  my $t0 = now;
  my $out;
  for ^2 { $out = js-minifier(input => $in, |$b<args>); }
  my $el = (now - $t0) / 2;
  say "{$b<label>}: {$el.fmt('%.3f')}s  => {($in.chars / $el / 1024).fmt('%.0f')} KB/s  (out { $out.chars } chars)";
}