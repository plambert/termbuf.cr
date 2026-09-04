# ameba:disable Lint/SpecFilename
# The input side has to stand on its own: it is going to be a shard of its own,
# and a require of nothing but `src/termbuf/input.cr` has to compile.
#
# This is not a spec — nothing here is run. It is compiled, by
# `crystal build --no-codegen spec/independence.cr`, and what it proves is that
# nothing under `src/termbuf/input/` reaches for a part of termbuf that is not
# coming with it.
require "../src/termbuf/input"

stream = TermBuf::Input::Stream.new IO::Memory.new, blocking: false
stream.patterns.register(TermBuf::Input::Prefix::CSI, terminator: "R") do |sequence|
  TermBuf::Events::Response.new sequence.bytes
end
