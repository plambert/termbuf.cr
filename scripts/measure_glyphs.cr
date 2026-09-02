#!/usr/bin/env crystal
#
# Measures what a terminal *draws*, which no escape sequence reports.
#
#     crystal run scripts/measure_glyphs.cr -- tmp/glyphs
#
# `CPR` says how many columns a terminal counts for a cluster. It says nothing
# about how wide the glyph is painted, nor about where the pen lands after it,
# and on some terminals those are three different numbers: Terminal.app counts
# four columns for `🏳️‍🌈`, paints it across two, and moves the pen by one, so
# whatever comes next is drawn on top of the flag.
#
# The only instrument for the other two is the screen. This writes a page of
# samples, has the terminal photograph itself, and moves on to the next page.
# `scripts/read_glyphs.py` reads the columns back out of the pictures.
#
# Each sample takes two rows:
#
#     <cluster><pad spaces>|     the bar says where the pen ended up
#     <cluster>                  nothing follows, so the glyph is intact
#
# Terminal.app draws over a neighbouring cell without repainting it — that is
# why a period lands on top of a flag rather than replacing it — so there both
# measurements could come off the first row. A terminal that repaints a cell
# from its buffer would erase the part of the glyph that overhangs, and the
# first row would then measure the pen rather than the paint. The bare row does
# not depend on which kind it is.
#
# Nothing here goes through `Buffer`, `Painter` or the capability probe. An
# instrument has no business running through what it is measuring, and a
# terminal that puts the pen somewhere unexpected leaves the encoder's idea of
# the cursor wrong for the rest of the frame — so a screen clear erases the
# wrong columns and the last page stays on screen underneath this one.
#
# Run it in the terminal being measured, with the font small and the window
# large. It needs permission to record the screen, which it inherits from the
# terminal it is running in — so run it from that terminal rather than from
# somewhere else, and from an instance started after the permission was granted,
# since a process is told what it may do when it starts.
#
# Terminal.app will say where its window is and only that window is
# photographed. No other terminal here will, so any other one has to be run
# fullscreen: the picture is then the whole screen, and the window is the only
# thing on it.
require "../src/termbuf"
require "./glyph_samples"

# Columns of space between a sample and its bar. It has to clear the widest
# glyph anything might draw, because the reader takes the bar to be the
# rightmost ink on that row -- and a glyph's ink runs past whatever was drawn
# after it, which is how a period ends up sitting inside a flag. An uncomposed
# tag sequence is the longest thing here at seven code points.
PAD = 20

# A staircase of bars at the top of every page: one on each row, each a column
# further along. Consecutive steps give the width of a cell and the height of a
# row at the same time, averaged over the lot, so the geometry comes off the
# picture rather than out of a font metric nobody told us.

# Steps in the staircase. Enough to average over, few enough to leave the page
# mostly samples.
CALIBRATION_STEPS = 6

# Writes one page of samples and photographs it.
#
# Everything goes out as escape sequences rather than through `Buffer` and
# `Painter`. An instrument has no business running through the thing it is
# measuring: on a terminal that puts the pen somewhere the encoder did not
# predict, the encoder's idea of the cursor is wrong for the rest of the frame,
# and the erases a screen clear turns into land in the wrong columns — which is
# how a page ended up with the last page's bars still on it.
#
# Every row is anchored with an absolute position of its own, so a sample that
# moves the pen unexpectedly can only spoil its own row. Within a row the text
# is written in one go, because where the bar lands is the measurement.
class Sheet
  def initialize(@tty : TermBuf::Tty, @bounds : String, @directory : String)
  end

  # Rows a page can hold: everything below the staircase, less one so a tall
  # glyph on the last row has somewhere to overhang.
  def capacity : Int32
    @tty.size.rows - CALIBRATION_STEPS - 1
  end

  def draw(page : Array(Sample)) : Nil
    @tty.output << String.build do |io|
      io << "\e[?25l\e[2J\e[H"
      CALIBRATION_STEPS.times { |step| io << at(step, step) << '|' }

      page.each_with_index do |sample, index|
        row = CALIBRATION_STEPS + index * 2
        io << at(0, row) << sample.text << " " * PAD << '|'
        io << at(0, row + 1) << sample.text
      end
    end

    @tty.output.flush
  end

  def photograph(number : Int32) : String
    path = File.join @directory, "page-#{number.to_s.rjust 2, '0'}.png"
    # Only the terminal's own window, not the screen it happens to be on --
    # where the terminal will say where its window is. Where it will not, the
    # window has to be the whole screen instead, and the caller has to have
    # made it so; see `window_bounds`.
    arguments = @bounds.empty? ? ["-x", path] : ["-x", "-R#{@bounds}", path]
    Process.run "screencapture", arguments
    path
  end

  # Cursor position, which counts from one where everything else here counts
  # from zero.
  private def at(column : Int32, row : Int32) : String
    "\e[#{row + 1};#{column + 1}H"
  end
end

# Where the window is, so the picture is of it and nothing else.
#
# Only Terminal.app will answer this. Nothing else here is scriptable enough to
# ask, and taking the whole screen instead would photograph whatever else is on
# it -- so for any other terminal the window has to *be* the whole screen, run
# fullscreen, and the empty string says to take it whole.
def window_bounds : String
  return "" unless ENV["TERM_PROGRAM"]? == "Apple_Terminal"

  script = <<-APPLESCRIPT
    tell application "Terminal"
      set b to bounds of front window
      return (item 1 of b as text) & "," & (item 2 of b as text) & "," & \
             ((item 3 of b) - (item 1 of b) as text) & "," & \
             ((item 4 of b) - (item 2 of b) as text)
    end tell
    APPLESCRIPT

  output = IO::Memory.new
  Process.run "osascript", ["-e", script], output: output
  output.to_s.strip
end

directory = ARGV[0]? || "tmp/glyphs"
Dir.mkdir_p directory
bounds = window_bounds

manifest = [] of String
taken_pages = 0
taken_samples = 0

# The alternate screen and raw mode, and nothing else. No probing, no width
# measurement, no buffer: whatever ends up on the screen came from the escape
# sequences below and from the terminal's own opinion of them.
tty = TermBuf::Tty.standard
tty.enter TermBuf::Capabilities::ANSI
rows_used = tty.size.rows

begin
  sheet = Sheet.new tty, bounds, directory
  remaining = samples

  # Two rows a sample, so a page holds half what it looks like it might.
  per_page = Math.max sheet.capacity // 2, 1

  while remaining.present?
    page = remaining[0, per_page]
    remaining = remaining[page.size..]
    taken_pages += 1

    sheet.draw page
    sleep 400.milliseconds
    sheet.photograph taken_pages
    sleep 200.milliseconds

    page.each_with_index do |sample, index|
      manifest << [taken_pages, CALIBRATION_STEPS + index * 2,
                   sample.text.codepoints.map { |point| "%04X" % point }.join('+'),
                   sample.group, sample.note].join('\t')
    end

    taken_samples += page.size
  end
ensure
  tty.output << "\e[?25h"
  tty.output.flush
  tty.leave TermBuf::Capabilities::ANSI
end

File.write File.join(directory, "manifest.tsv"),
  (["# pad=#{PAD} steps=#{CALIBRATION_STEPS} rows=#{rows_used}",
    "page\tbar_row\tcodepoints\tgroup\tnote"] + manifest).join('\n') + "\n"

puts "#{taken_samples} samples over #{taken_pages} pages in #{directory}"
puts "pad=#{PAD} steps=#{CALIBRATION_STEPS} rows=#{rows_used} bounds=#{bounds}"
puts "now: python3 scripts/read_glyphs.py #{directory}"
