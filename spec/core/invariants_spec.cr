require "../spec_helper"

# Randomized checks on the two properties the paint algorithm will lean on.
#
# The first is that a wide character always occupies exactly two adjacent
# cells. Getting that wrong produces a grid the painter can encode faithfully
# and still leave the screen corrupt, because the terminal's idea of where the
# cursor is diverges from the buffer's.
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
  "क्ष",                # an Indic conjunct
  "ab", "a漢b", "x́y",
]

private STYLES = [
  TermBuf::Style::DEFAULT,
  TermBuf::Style::DEFAULT.bold,
  TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED),
  TermBuf::Style::DEFAULT.bg(TermBuf::Color.rgb(10, 20, 30)),
  TermBuf::Style::DEFAULT.underlined(TermBuf::Underline::Curly),
]

private def check_pairing(grid : TermBuf::Grid) : String?
  grid.height.times do |row|
    grid.width.times do |column|
      cell = grid[column, row]

      if cell.continuation?
        return "continuation at #{column},#{row} with no lead" if column.zero?

        lead = grid[column - 1, row]
        return "continuation at #{column},#{row} follows #{lead}" unless lead.wide?
      elsif cell.wide?
        if column + 1 >= grid.width
          return "wide character at #{column},#{row} in the last column"
        end

        follower = grid[column + 1, row]
        unless follower.continuation?
          return "wide character at #{column},#{row} followed by #{follower}"
        end
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
  sample [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64] do |seed|
    it "holds across a random sequence of operations (seed #{seed})" do
      random = Random.new seed
      buffer = TermBuf::Buffer.new 12, 6
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

  # Damage is monotone within a paint cycle: a write that changes a cell and a
  # later one that puts it back both mark it, so replaying an overlapping
  # sequence leaves damage behind even though nothing ended up different. What
  # has to hold is that the *content* is the same either way.
  it "reaches the same grid when an overlapping sequence is replayed" do
    buffer = TermBuf::Buffer.new 12, 6
    random = Random.new 99_u64
    operations = Array.new(40) { {random.rand(12), random.rand(6), ALPHABET.sample(random)} }

    operations.each { |(x, y, text)| buffer.write x, y, text }
    buffer.commit_paint
    operations.each { |(x, y, text)| buffer.write x, y, text }

    expect(buffer.painted?).to be_true
  end

  it "reports no damage when non-overlapping writes are replayed" do
    buffer = TermBuf::Buffer.new 12, 6

    buffer.height.times do |row|
      buffer.width.times { |column| buffer.write_char column, row, 'a' + column }
    end

    buffer.commit_paint

    buffer.height.times do |row|
      buffer.width.times { |column| buffer.write_char column, row, 'a' + column }
    end

    expect(buffer.dirty?).to be_false
  end
end

private def apply_operation(buffer : TermBuf::Buffer, random : Random) : Nil
  case random.rand 10
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
  else
    buffer.clear STYLES.sample(random)
  end
end

private def random_rect(buffer : TermBuf::Buffer, random : Random) : TermBuf::Rect
  x = random.rand buffer.width
  y = random.rand buffer.height

  TermBuf::Rect.new x, y, random.rand(1..buffer.width - x), random.rand(1..buffer.height - y)
end
