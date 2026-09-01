#!/usr/bin/env crystal
#
# Measures what a terminal *counts* for a cluster, which is the one width an
# escape sequence will tell you.
#
#     crystal run scripts/measure_columns.cr -- measurements/<name>
#
# `scripts/measure_glyphs.cr` photographs where the pen lands and how wide the
# ink runs. Neither of those is the number the terminal charges the row, and on
# Terminal.app all three differ: `🏳️‍🌈` counts 4, advances 1, is drawn 2. This
# asks for the third by writing a cluster at a known column and reading `CPR`
# back — the counted width is where the cursor ended up, less where it started.
#
# It shares its sample list with the photographic instrument so the two sets of
# readings are answers about the same clusters.
#
# Like that instrument, nothing here goes through `Buffer`, `Painter` or the
# capability probe: a terminal that leaves the cursor somewhere unexpected is
# the thing being measured, so it cannot also be the thing keeping the books.
require "../src/termbuf"
require "./glyph_samples"

# Long enough that a terminal which answers at all has answered, short enough
# that one which never will does not hold the run up. Terminal.app replies in
# under a millisecond; the margin is for a slow ssh hop.
TIMEOUT = 250.milliseconds

# Reads one `CPR` reply, as the column the cursor is in. Nil when the terminal
# said nothing in time, which is a measurement too: it means the run cannot be
# trusted rather than that the width was zero.
def cursor_column(tty : TermBuf::Tty) : Int32?
  tty.output << "\e[6n"
  tty.output.flush

  input = tty.input
  return unless input.responds_to?(:read_timeout=)

  previous = input.read_timeout
  reply = String.build do |io|
    input.read_timeout = TIMEOUT
    while byte = input.read_byte
      io << byte.unsafe_chr
      break if byte === 'R'.ord
    end
  rescue IO::TimeoutError
    return
  ensure
    input.read_timeout = previous
  end

  # `ESC [ row ; column R`, and nothing else is worth reading.
  if match = reply.match(/\e\[(\d+);(\d+)R/)
    match[2].to_i
  end
end

directory = ARGV[0]? || "tmp/glyphs"
Dir.mkdir_p directory

rows = [] of String
missing = 0

tty = TermBuf::Tty.standard
tty.enter TermBuf::Capabilities::ANSI

begin
  # Anything already buffered from the terminal would be read as this run's
  # first reply, so ask once and throw the answer away before starting.
  cursor_column tty

  samples.each do |sample|
    # Each sample gets the top row to itself, cleared, so a cluster that
    # overhung the last one cannot be charged to this one.
    tty.output << "\e[H\e[2K"
    tty.output.flush

    start = cursor_column tty
    tty.output << sample.text
    tty.output.flush
    finish = cursor_column tty

    counted = if start && finish
                finish - start
              else
                missing += 1
                nil
              end

    points = sample.text.codepoints.map { |point| "%04X" % point }.join('+')
    rows << [points, sample.group,
             counted || "",
             TermBuf::Unicode.string_width(sample.text),
             TermBuf::Unicode.code_point_columns(sample.text),
             sample.note].join('\t')
  end
ensure
  tty.leave TermBuf::Capabilities::ANSI
end

path = File.join directory, "counted.tsv"
File.write path,
  (["codepoints\tgroup\tcounted\tcluster_width\tcode_point_sum\tnote"] + rows).join('\n') + "\n"

puts "#{rows.size} samples to #{path}"
puts "#{missing} without an answer" if missing > 0
