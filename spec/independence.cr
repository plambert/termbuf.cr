# ameba:disable Lint/SpecFilename
# The input side has to stand on its own: it is going to be a shard of its own,
# and a require of nothing but `src/termbuf/input.cr` has to compile.
#
# This is not a spec — nothing here is run. It is compiled, by
# `crystal build --no-codegen spec/independence.cr`, and what it proves is that
# nothing under `src/termbuf/input/` reaches for a part of termbuf that is not
# coming with it.
require "../src/termbuf/input"

# The compiler saw every file that require pulled in, so a name only the rest
# of termbuf defines being present means one of those files came along too. CI
# checks the same thing from the outside, over `crystal tool dependencies`;
# this catches it here, with a better message.
{% for absent in %w[ScreenSize SizeDetector Unicode Terminal Buffer Style] %}
  {% if TermBuf.has_constant? absent %}
    {% raise "termbuf/input pulled in TermBuf::#{absent.id}: the input side is " +
             "meant to compile without the rest of termbuf" %}
  {% end %}
{% end %}

stream = TermBuf::Input::Stream.new IO::Memory.new, blocking: false
stream.patterns.register(TermBuf::Input::Prefix::CSI, terminator: "R") do |sequence|
  TermBuf::Input::Events::Response.new sequence.bytes
end
