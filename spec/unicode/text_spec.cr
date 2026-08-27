require "../spec_helper"

private alias Uni = TermBuf::Unicode

# A wide cluster, a zero-width mark, and a joined emoji, so a fit has to
# consult the policy rather than count characters.
private WIDE   = "世"                             # CJK ideograph, two cells
private MARK   = "é"                            # e + combining acute, one cell
private FAMILY = "\u{1F468}‍\u{1F469}‍\u{1F467}" # ZWJ family, two cells

Spectator.describe TermBuf::Unicode do
  after_each { Uni.policy = Uni::WidthPolicy::DEFAULT }

  describe ".truncate" do
    it "returns the string untouched when it already fits" do
      expect(Uni.truncate("hello", 5)).to eq "hello"
      expect(Uni.truncate("hello", 9)).to eq "hello"
      expect(Uni.truncate("", 4)).to eq ""
    end

    it "cuts to the width asked for" do
      expect(Uni.truncate("hello world", 5)).to eq "hello"
      expect(Uni.truncate("hello", 1)).to eq "h"
    end

    it "returns nothing for a width of zero or less" do
      expect(Uni.truncate("hello", 0)).to eq ""
      expect(Uni.truncate("hello", -3)).to eq ""
    end

    it "drops a wide cluster that would straddle the edge" do
      text = "a#{WIDE}b"
      expect(Uni.string_width(text)).to eq 4
      expect(Uni.truncate(text, 2)).to eq "a"
      expect(Uni.truncate(text, 3)).to eq "a#{WIDE}"
    end

    it "keeps a combining mark with the character it belongs to" do
      expect(Uni.truncate("#{MARK}xyz", 1)).to eq MARK
      expect(Uni.truncate("x#{MARK}", 2)).to eq "x#{MARK}"
    end

    it "treats a joined emoji as one cluster" do
      expect(Uni.string_width(FAMILY)).to eq 2
      expect(Uni.truncate("#{FAMILY}!", 1)).to eq ""
      expect(Uni.truncate("#{FAMILY}!", 2)).to eq FAMILY
      expect(Uni.truncate("#{FAMILY}!", 3)).to eq "#{FAMILY}!"
    end

    it "measures against the policy it is given" do
      narrow = Uni::WidthPolicy::DEFAULT.copy_with joined_emoji: false
      expect(Uni.string_width(FAMILY, narrow)).to eq 6
      expect(Uni.truncate(FAMILY, 2, narrow)).to eq ""
    end
  end

  describe ".ellipsize" do
    it "returns the string untouched when it already fits" do
      expect(Uni.ellipsize("hello", 5)).to eq "hello"
      expect(Uni.ellipsize("hello", 8)).to eq "hello"
    end

    it "makes room for the marker" do
      expect(Uni.ellipsize("hello world", 8)).to eq "hello w…"
      expect(Uni.string_width(Uni.ellipsize("hello world", 8))).to eq 8
    end

    it "measures a marker wider than one cell" do
      expect(Uni.ellipsize("hello world", 8, "...")).to eq "hello..."
      expect(Uni.ellipsize("hello world", 6, WIDE)).to eq "hell#{WIDE}"
    end

    it "cuts without a marker when the marker alone will not fit" do
      expect(Uni.ellipsize("hello", 2, "...")).to eq "he"
      expect(Uni.ellipsize("hello", 1, WIDE)).to eq "h"
    end

    it "is exactly the marker when there is room for nothing else" do
      expect(Uni.ellipsize("hello", 1)).to eq "…"
    end

    it "returns nothing for a width of zero or less" do
      expect(Uni.ellipsize("hello", 0)).to eq ""
      expect(Uni.ellipsize("hello", -1)).to eq ""
    end

    it "never comes back wider than the width asked for" do
      %w[a ab hello 世界 x].each do |text|
        (0..8).each do |width|
          expect(Uni.string_width(Uni.ellipsize(text, width))).to be <= width
        end
      end
    end
  end

  describe ".fit" do
    it "pads a short string on the right by default" do
      expect(Uni.fit("ab", 5)).to eq "ab   "
    end

    it "pads a short string on the left when right-aligned" do
      expect(Uni.fit("42", 6, :right)).to eq "    42"
    end

    it "splits the padding when centred, the odd cell going right" do
      expect(Uni.fit("ab", 6, :center)).to eq "  ab  "
      expect(Uni.fit("ab", 7, :center)).to eq "  ab   "
    end

    it "cuts a string that is too long" do
      expect(Uni.fit("hello world", 5)).to eq "hello"
      expect(Uni.fit("hello world", 5, :right)).to eq "hello"
    end

    it "pads the cell left over by a dropped wide cluster" do
      expect(Uni.fit("a#{WIDE}b", 2)).to eq "a "
      expect(Uni.fit("a#{WIDE}b", 2, :right)).to eq " a"
    end

    it "uses the fill character it is given" do
      expect(Uni.fit("ab", 6, :left, '.')).to eq "ab...."
      expect(Uni.fit("", 4, :left, '-')).to eq "----"
    end

    it "makes up the remainder with spaces when the fill is wide" do
      expect(Uni.fit("a", 6, :left, '世')).to eq "a世世 "
      expect(Uni.string_width(Uni.fit("a", 6, :left, '世'))).to eq 6
    end

    it "falls back to spaces for a zero-width fill" do
      expect(Uni.fit("a", 4, :left, '́')).to eq "a   "
    end

    it "returns nothing for a width of zero or less" do
      expect(Uni.fit("hello", 0)).to eq ""
      expect(Uni.fit("hello", -2, :right)).to eq ""
    end

    it "comes back exactly the width asked for" do
      ["", "a", "hello world", "世界の", MARK, FAMILY].each do |text|
        (0..10).each do |width|
          {Uni::Align::Left, Uni::Align::Right, Uni::Align::Center}.each do |align|
            expect(Uni.string_width(Uni.fit(text, width, align))).to eq width
          end
        end
      end
    end
  end

  describe ".window" do
    it "takes the cells starting at the offset" do
      expect(Uni.window("abcdefgh", 2, 3)).to eq "cde"
      expect(Uni.window("abcdefgh", 0, 3)).to eq "abc"
    end

    it "comes back short when the window runs past the end" do
      expect(Uni.window("abc", 1, 10)).to eq "bc"
      expect(Uni.window("abc", 9, 4)).to eq ""
    end

    it "drops a wide cluster crossing either edge" do
      text = "a#{WIDE}b" # cells: a . . b
      expect(Uni.window(text, 0, 2)).to eq "a"
      expect(Uni.window(text, 1, 2)).to eq WIDE
      expect(Uni.window(text, 2, 2)).to eq "b"
      expect(Uni.window(text, 0, 3)).to eq "a#{WIDE}"
    end

    it "starts before the text when the offset is negative" do
      expect(Uni.window("abc", -2, 4)).to eq "ab"
      expect(Uni.window("abc", -5, 2)).to eq ""
    end

    it "returns nothing for a width of zero or less" do
      expect(Uni.window("abc", 0, 0)).to eq ""
      expect(Uni.window("abc", 1, -1)).to eq ""
    end

    it "never comes back wider than the window" do
      text = "a#{WIDE}b#{FAMILY}c#{MARK}"
      (-3..12).each do |offset|
        (0..8).each do |width|
          expect(Uni.string_width(Uni.window(text, offset, width))).to be <= width
        end
      end
    end

    it "reassembles the whole string from consecutive windows" do
      text = "a#{WIDE}bc"
      pieces = [0, 1, 3].map { |offset| Uni.window text, offset, offset.zero? ? 1 : 2 }
      expect(pieces.join).to eq text
    end
  end

  describe "the default policy" do
    it "is what an unqualified call measures against" do
      Uni.policy = Uni::WidthPolicy::DEFAULT.copy_with ambiguous: 2

      expect(Uni.truncate("¡¡", 2)).to eq "¡"
      expect(Uni.fit("¡", 4)).to eq "¡  "
    end
  end
end
