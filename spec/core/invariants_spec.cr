require "../spec_helper"

# Randomized checks on the two properties the paint algorithm will lean on.
#
# The first is that a cluster of width N always occupies exactly N adjacent
# cells: a lead and N-1 continuations, all on the grid. Getting that wrong
# produces a grid the painter can encode faithfully and still leave the screen
# corrupt, because the terminal's idea of where the cursor is diverges from the
# buffer's.
#
# The second is that damage is *sound*: every cell that changed is inside the
# damage span recorded for its row. The painter only scans those spans, so a
# change outside one would silently never be drawn. Damage may over-report —
# that only costs a scan — but it must never under-report.
private ALPHABET = [
  "a", "b", "Z", " ", "#", "0",
  "漢", "か", "한",        # wide
  "é", "á̂",            # combining
  "😀", "☀️",            # emoji, with and without a variation selector
  "\u{1F1FA}\u{1F1F8}", # a flag, two code points in one wide cell
  "क्ष", "क्षि",        # an Indic conjunct, and one carrying a vowel sign
  "ab", "a漢b", "x́y",
]

# The default, and the one a terminal charging three columns for `क्षि` gets:
# the same grid has to hold a cluster wider than a pair.
private DEFAULT_POLICY       = TermBuf::Unicode::WidthPolicy::DEFAULT
private WIDE_CONJUNCT_POLICY =
  TermBuf::Unicode::WidthPolicy::DEFAULT.with "conjunct_spacing_adds", true

private STYLES = [
  TermBuf::Style::DEFAULT,
  TermBuf::Style::DEFAULT.bold,
  TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED),
  TermBuf::Style::DEFAULT.bg(TermBuf::Color.rgb(10, 20, 30)),
  TermBuf::Style::DEFAULT.underlined(TermBuf::Underline::Curly),
]

# A blend is answered per cell, so a write or a fill carrying one places its
# cells one at a time rather than going through `Grid#fill`. The pairing and
# damage invariants have to survive that path as well.
private BLENDS = [
  TermBuf::Style::KEEP_BACKGROUND,
  TermBuf::Style::OVER,
  TermBuf::Style.blend { |under, over| under.merge(over).faint },
]

private def check_pairing(grid : TermBuf::Grid) : String?
  grid.height.times do |row|
    grid.width.times do |column|
      if failure = check_cell grid, column, row
        return failure
      end
    end
  end

  nil
end

# A lead of width N is followed by exactly N-1 continuations and its whole
# extent is on the grid; a continuation belongs to the lead found by walking
# left, whose extent covers it.
private def check_cell(grid : TermBuf::Grid, column : Int32, row : Int32) : String?
  cell = grid[column, row]

  if cell.continuation?
    lead_column = column
    while lead_column > 0 && grid[lead_column, row].continuation?
      lead_column -= 1
    end

    if lead_column == column
      return "continuation at #{column},#{row} with no lead"
    end

    lead = grid[lead_column, row]
    unless lead.wide? && lead_column + lead.width > column
      return "continuation at #{column},#{row} is not covered by #{lead} at #{lead_column}"
    end
  elsif cell.wide?
    span = cell.width.to_i

    if column + span > grid.width
      return "#{span} column cluster at #{column},#{row} runs off the grid"
    end

    (1...span).each do |offset|
      follower = grid[column + offset, row]
      unless follower.continuation?
        return "#{span} column cluster at #{column},#{row} followed by #{follower}"
      end
    end
  end

  nil
end

private def check_damage(grid : TermBuf::Grid, snapshot : TermBuf::Grid) : String?
  grid.height.times do |row|
    span = grid.damage.span row

    grid.width.times do |column|
      next if grid[column, row] == snapshot[column, row]
      next if span && span.includes? column

      return "cell #{column},#{row} changed but the row's damage is #{span.inspect}"
    end
  end

  nil
end

Spectator.describe "core buffer invariants" do
  # A fixed seed so a failure is reproducible; widen the range when hunting.
  {% for widths in [{"DEFAULT_POLICY", "the default policy"},
                    {"WIDE_CONJUNCT_POLICY", "a three column cluster"}] %}
    describe "under {{ widths[1].id }}" do
      sample [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64] do |seed|
        it "holds across a random sequence of operations (seed #{seed})" do
          random = Random.new seed
          buffer = TermBuf::Buffer.new 12, 6
          buffer.policy = {{ widths[0].id }}
          snapshot = TermBuf::Grid.new 12, 6

          300.times do |step|
            snapshot.copy_from buffer.back
            buffer.back.damage.clear

            apply_operation buffer, random

            if failure = check_pairing buffer.back
              fail "seed #{seed}, step #{step}: #{failure}"
            end

            if failure = check_damage buffer.back, snapshot
              fail "seed #{seed}, step #{step}: #{failure}"
            end
          end
        end
      end
    end
  {% end %}

  # Damage is monotone within a paint cycle: a write that changes a cell and a
  # later one that puts it back both mark it, so replaying an overlapping
  # sequence leaves damage behind even though nothing ended up different. What
  # has to hold is that the *content* is the same either way.
  it "reaches the same grid when an overlapping sequence is replayed" do
    buffer = TermBuf::Buffer.new 12, 6
    random = Random.new 99_u64
    operations = Array.new(40) { {random.rand(12), random.rand(6), ALPHABET.sample(random)} }

    sink = TermBuf::Sink.new buffer, TermBuf::Capabilities::XTERM

    operations.each { |(x, y, text)| buffer.write x, y, text }
    sink.commit
    operations.each { |(x, y, text)| buffer.write x, y, text }

    expect(sink.painted?).to be_true
  end

  it "reports no damage when non-overlapping writes are replayed" do
    buffer = TermBuf::Buffer.new 12, 6
    sink = TermBuf::Sink.new buffer, TermBuf::Capabilities::XTERM

    buffer.height.times do |row|
      buffer.width.times { |column| buffer.write_char column, row, 'a' + column }
    end

    sink.commit

    buffer.height.times do |row|
      buffer.width.times { |column| buffer.write_char column, row, 'a' + column }
    end

    expect(buffer.dirty?).to be_false
  end
end

private def apply_operation(buffer : TermBuf::Buffer, random : Random) : Nil
  case random.rand 12
  when 0, 1, 2, 3, 4
    buffer.write random.rand(buffer.width), random.rand(buffer.height),
      ALPHABET.sample(random), STYLES.sample(random)
  when 5
    buffer.write_char random.rand(buffer.width), random.rand(buffer.height),
      ALPHABET.sample(random)[0], STYLES.sample(random)
  when 6, 7
    buffer.scroll random_rect(buffer, random), random.rand(-3..3), STYLES.sample(random)
  when 8
    buffer.fill random_rect(buffer, random), '#', STYLES.sample(random)
  when 9
    buffer.write random.rand(buffer.width), random.rand(buffer.height),
      ALPHABET.sample(random), STYLES.sample(random), blend: BLENDS.sample(random)
  when 10
    buffer.fill random_rect(buffer, random), '.', STYLES.sample(random),
      blend: BLENDS.sample(random)
  else
    buffer.clear STYLES.sample(random)
  end
end

private def random_rect(buffer : TermBuf::Buffer, random : Random) : TermBuf::Rect
  x = random.rand buffer.width
  y = random.rand buffer.height

  TermBuf::Rect.new x, y, random.rand(1..buffer.width - x), random.rand(1..buffer.height - y)
end
