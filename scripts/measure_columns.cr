#!/usr/bin/env crystal
#
# Measures what a terminal *counts* for a cluster, which is the one width an
# escape sequence will tell you.
#
#     crystal run scripts/measure_columns.cr -- measurements/<name> [corpus.tsv]
#
# `scripts/measure_glyphs.cr` photographs where the pen lands and how wide the
# ink runs. Neither of those is the number the terminal charges the row, and on
# Terminal.app all three differ: `🏳️‍🌈` counts 4, advances 1, is drawn 2. This
# asks for the third by writing a cluster at a known column and reading `CPR`
# back — the counted width is where the cursor ended up, less the column it was
# put at.
#
# With no corpus named it measures the sixty seven it shares with the
# photographic instrument, so the two sets of readings are about the same
# clusters. Named a corpus — `measurements/corpus.tsv`, five thousand of them —
# it measures that instead. See `measurements/SURVEY.md`.
#
# Nothing here goes through `Buffer`, `Painter` or the capability probe: a
# terminal that leaves the cursor somewhere unexpected is the thing being
# measured, so it cannot also be the thing keeping the books.
require "../src/termbuf"
require "./glyph_samples"

# Long enough that a terminal which answers at all has answered, short enough
# that one which never will does not hold the run up. Terminal.app replies in
# under a millisecond; the margin is for a slow ssh hop, and a whole batch is
# allowed this much again for every sample in it.
TIMEOUT = 250.milliseconds

# Samples written before anything is read back. Five thousand clusters is ten
# thousand round trips one at a time, which is most of the run; batched it is
# fifty. A batch that comes back short is thrown away and repeated one at a
# time, so this trades nothing for the speed.
BATCH = 100

# Reads cursor position reports until *count* have arrived or nothing has
# arrived for *idle*. Anything that is not a report is a keystroke, and is
# counted rather than mistaken for an answer.
#
# The wait is for a gap rather than for a total, because a terminal answers a
# batch back to back: a quarter second of silence means the rest is not coming.
# Waiting a whole batch's worth of timeout instead made a batch that lost one
# reply cost twenty-five seconds.
def read_columns(input : IO, count : Int32, idle : Time::Span = TIMEOUT) : {Array(Int32), Int32}
  columns = [] of Int32
  pending = IO::Memory.new
  strays = 0
  buffer = Bytes.new 4096

  while columns.size < count
    break unless input.responds_to? :read_timeout=

    input.read_timeout = idle
    read = begin
      input.read buffer
    rescue IO::TimeoutError
      break
    end
    break if read.nil? || read.zero?

    pending.write buffer[0, read]
    text = pending.to_s
    pending.clear

    # `ESC [ row ; column R`, in the order they arrived. A partial reply at the
    # end of the buffer is kept for the next read rather than dropped.
    last = 0
    text.scan(/\e\[(\d+);(\d+)R/) do |match|
      columns << match[2].to_i
      last = match.end || last
    end

    tail = text[last..]
    strays += tail.count { |char| char != '\e' } if tail.size > 16
    pending << (tail.size > 16 ? "" : tail)
  end

  {columns, strays}
end

# Writes one sample at the left margin of *row*, with the line cleared first so
# a cluster that overhung the last one cannot be charged to this one, and asks
# where the cursor ended up.
def place(io : IO, row : Int32, text : String) : Nil
  io << "\e[" << row << ";1H\e[2K" << text << "\e[6n"
end

# Everything worth recording about where a run happened. The font does not move
# this measurement — three of them proved that — but writing it down is how
# that was proved.
def environment(tty : TermBuf::Tty) : Hash(String, String)
  size = tty.size
  found = {
    "date"                 => Time.local.to_s("%Y-%m-%d %H:%M:%S"),
    "term"                 => ENV.fetch("TERM", ""),
    "term_program"         => ENV.fetch("TERM_PROGRAM", ""),
    "term_program_version" => ENV.fetch("TERM_PROGRAM_VERSION", ""),
    "columns"              => size.columns.to_s,
    "rows"                 => size.rows.to_s,
  }

  # A multiplexer names itself in the environment, and its version matters as
  # much as the terminal's: two builds of GNU screen twenty years apart are two
  # different answers.
  #
  # Asking the one on the `PATH` is not good enough to tell them apart — it
  # answered "5.0.2" for a run made by `/usr/bin/screen`, which is 4.00.03 — so
  # a caller that knows which binary it launched says so, and that is believed
  # over anything discovered here.
  if tmux = ENV["TMUX"]?
    found["multiplexer"] = "tmux"
    found["multiplexer_socket"] = tmux.split(',').first
    found["multiplexer_version"] = version_of "tmux -V"
  elsif session = ENV["STY"]?
    found["multiplexer"] = "screen"
    found["multiplexer_session"] = session
    found["multiplexer_version"] = version_of "screen --version"
  end

  if layer = ENV["TERMBUF_LAYER"]?
    found["multiplexer"] = layer
  end
  if binary = ENV["TERMBUF_LAYER_BIN"]?
    found["multiplexer_binary"] = binary
    found["multiplexer_version"] = version_of "#{binary} --version"
  end

  found
end

# What a program says its version is, or nothing when it cannot be asked.
def version_of(command : String) : String
  `#{command}`.strip
rescue
  ""
end

# What `DECRPM` says about a mode it was asked for.
MODE_STATES = {
  "0" => "unsupported",
  "1" => "set",
  "2" => "reset",
  "3" => "permanently set",
  "4" => "permanently reset",
}

# Whether the terminal has mode 2027, grapheme cluster counting, and what it is
# set to. `DECRPM` answers `ESC [ ? 2027 ; ps $ y`, where ps is 0 for a mode it
# does not know, 1 set, 2 reset, 3 permanently set, 4 permanently reset.
def grapheme_mode(tty : TermBuf::Tty) : String
  tty.output << "\e[?2027$p"
  tty.output.flush

  input = tty.input
  return "unknown" unless input.responds_to? :read_timeout=

  deadline = Time.instant + TIMEOUT
  buffer = Bytes.new 256
  seen = IO::Memory.new

  while Time.instant < deadline
    input.read_timeout = deadline - Time.instant
    read = begin
      input.read buffer
    rescue IO::TimeoutError
      break
    end
    break if read.nil? || read.zero?

    seen.write buffer[0, read]
    break if seen.to_s.includes? "$y"
  end

  return "unanswered" unless match = seen.to_s.match(/\e\[\?2027;(\d+)\$y/)

  MODE_STATES.fetch match[1], "ps=#{match[1]}"
end

# The corpus at *path*, as written by `scripts/gen_corpus.cr`.
def corpus(path : String) : Array(Sample)
  entries = [] of Sample

  File.each_line path do |line|
    next if line.starts_with?('#') || line.starts_with?("codepoints\t")

    fields = line.split '\t'
    next if fields.size < 3

    text = fields[0].split('+').map(&.to_i(16).chr).join
    entries << Sample.new text, fields[1], fields[2]
  end

  entries
end

directory = ARGV[0]? || "tmp/glyphs"
list = (path = ARGV[1]?) ? corpus(path) : samples
Dir.mkdir_p directory

abort "no samples in #{ARGV[1]?}" if list.empty?

counted = Array(Int32?).new list.size, nil
strays = 0
missing = 0

tty = TermBuf::Tty.standard
tty.enter TermBuf::Capabilities::ANSI

# Autowrap off, so a cluster the terminal counts generously wraps nowhere and
# cannot take the reading after it along.
tty.output << "\e[?7l"
tty.output.flush

mode = grapheme_mode tty
usable_rows = Math.max tty.size.rows - 1, 1

silent = false

begin
  offset = 0

  list.each_slice BATCH do |batch|
    tty.output << String.build do |io|
      batch.each_with_index { |sample, index| place io, index % usable_rows + 1, sample.text }
    end
    tty.output.flush

    answers, batch_strays = read_columns tty.input, batch.size
    strays += batch_strays

    # A terminal that says nothing to the first hundred is not going to say
    # anything to the next five thousand, and asking them one at a time would
    # spend a quarter second each finding that out — twenty minutes to reach a
    # conclusion available now.
    if offset.zero? && answers.empty?
      silent = true
      break
    end

    if answers.size == batch.size
      answers.each_with_index { |column, index| counted[offset + index] = column - 1 }
      next
    end

    # A dropped reply puts every answer after it against the wrong cluster, so
    # nothing from a short batch is believed. Asking again one at a time costs
    # a round trip each and cannot be misattributed.
    STDERR.puts "batch at #{offset} answered #{answers.size} of #{batch.size}; repeating singly"

    batch.each_with_index do |sample, index|
      tty.output << String.build { |io| place io, 1, sample.text }
      tty.output.flush

      single, _ = read_columns tty.input, 1
      if column = single.first?
        counted[offset + index] = column - 1
      else
        missing += 1
      end
    end
  ensure
    offset += batch.size
  end
ensure
  tty.output << "\e[?7h"
  tty.output.flush
  tty.leave TermBuf::Capabilities::ANSI
end

abort "no answer to the first #{BATCH}: this terminal does not report the cursor" if silent

answered = counted.count { |column| column }
abort "#{list.size} samples and not one answer: this terminal does not report the cursor" if answered.zero?

File.open File.join(directory, "environment.tsv"), "w" do |file|
  file << "key\tvalue\n"
  environment(tty).each { |key, value| file << key << '\t' << value << '\n' }
  file << "grapheme_mode_2027\t" << mode << '\n'
  file << "corpus\t" << (ARGV[1]? || "scripts/glyph_samples.cr") << '\n'
  file << "samples\t" << list.size << '\n'
  file << "unanswered\t" << list.size - answered << '\n'
end

path = File.join directory, "counted.tsv"
File.open path, "w" do |file|
  file << "codepoints\tgroup\tcounted\tcluster_width\tcode_point_sum\tnote\n"

  list.each_with_index do |sample, index|
    points = sample.text.codepoints.map { |point| "%04X" % point }.join '+'
    file << points << '\t' << sample.group << '\t' << (counted[index] || "") << '\t'
    file << TermBuf::Unicode.string_width(sample.text) << '\t'
    file << TermBuf::Unicode.code_point_columns(sample.text) << '\t'
    file << sample.note << '\n'
  end
end

puts "#{list.size} samples to #{path}"
puts "#{list.size - answered} without an answer" if answered < list.size
puts "#{strays} stray bytes read, which were keystrokes or reports nobody asked for" if strays > 0
puts "mode 2027: #{mode}"
