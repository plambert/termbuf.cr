require "../spec_helper"

# Runs the full UAX #29 extended grapheme cluster break test from the Unicode
# Character Database. Each line of the fixture is a sequence of code points
# separated by division signs (a boundary) and multiplication signs (no
# boundary); the breaker has to agree with every one of them.
#
# The fixture is refreshed by `scripts/gen_unicode.cr` alongside the tables, so
# the two can never disagree about which Unicode version they describe.
private FIXTURE = File.join __DIR__, "..", "fixtures", "GraphemeBreakTest.txt"

private record ConformanceCase,
  line : Int32,
  source : String,
  expected : Array(String),
  description : String

# Parses a fixture line such as:
#
#     ÷ 0020 ÷ 0308 × 0020 ÷  #  ÷ [0.2] SPACE ÷ [999.0] ...
private def parse_case(line : String, number : Int32) : ConformanceCase?
  body, _, comment = line.partition '#'
  body = body.strip
  return if body.empty?

  clusters = [] of String
  current = String::Builder.new

  body.split(' ').each do |token|
    case token
    when "÷" # division sign: a cluster boundary
      text = current.to_s
      clusters << text unless text.empty?
      current = String::Builder.new
    when "×" # multiplication sign: no boundary here
      # nothing to do; the next code point joins the current cluster
    when ""
      # collapsed whitespace
    else
      current << token.to_i(16).chr
    end
  end

  text = current.to_s
  clusters << text unless text.empty?
  return if clusters.empty?

  ConformanceCase.new number, clusters.join, clusters, comment.strip
end

Spectator.describe "UAX #29 grapheme cluster conformance" do
  it "matches every case in GraphemeBreakTest.txt" do
    cases = [] of ConformanceCase

    File.each_line FIXTURE do |line|
      if parsed = parse_case line, cases.size + 1
        cases << parsed
      end
    end

    expect(cases.size).to be > 600

    failures = [] of String

    cases.each do |testcase|
      actual = TermBuf::Unicode.graphemes testcase.source
      next if actual == testcase.expected

      failures << String.build do |io|
        io << "case " << testcase.line << ": expected "
        io << testcase.expected.map { |cluster| codepoints(cluster) }.inspect
        io << " but got " << actual.map { |cluster| codepoints(cluster) }.inspect
        io << "\n  " << testcase.description
      end
    end

    expect(failures.first(10).join "\n").to eq ""
  end
end

private def codepoints(cluster : String) : String
  cluster.chars.map(&.ord.to_s(16).upcase.rjust(4, '0')).join ' '
end
