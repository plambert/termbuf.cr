require "../spec_helper"

private def buffer(text : String = "") : TermBuf::LineBuffer
  TermBuf::LineBuffer.new text
end

# The mixed alphabet the round-trip specs use, so the text model meets the same
# clusters the painter does.
private ALPHABET = [
  "a", "b", " ", "_", "1", "漢", "é", "é", "\u{1F44D}",
  "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1FA}\u{1F1F8}",
  "क्षि", "\n",
]

private def mixed(random : Random, length : Int32) : String
  String.build { |io| length.times { io << ALPHABET[random.rand ALPHABET.size] } }
end

Spectator.describe TermBuf::LineBuffer do
  describe "counting" do
    it "counts clusters rather than characters or bytes" do
      line = buffer "a\u{1F468}\u{200D}\u{1F469}b"

      expect(line.size).to eq 3
      expect(line.text.size).to eq 5
    end

    it "measures a cluster as the terminal would" do
      line = buffer "a漢"

      expect(line.width).to eq 3
      expect(line.width_at 1).to eq 2
    end

    it "measures with the policy it was given" do
      narrow = TermBuf::Unicode::WidthPolicy::DEFAULT.with "joined_emoji", false
      line = TermBuf::LineBuffer.new "\u{1F468}\u{200D}\u{1F469}", narrow

      expect(line.width).to eq 4
    end
  end

  describe "inserting" do
    it "puts text at the cursor and leaves it after" do
      line = buffer "ac"
      line.move_to 1
      line.insert "b"

      expect(line.text).to eq "abc"
      expect(line.cursor).to eq 2
    end

    it "counts an inserted cluster once however many code points it has" do
      line = buffer
      line.insert "\u{1F1FA}\u{1F1F8}"

      expect(line.size).to eq 1
      expect(line.cursor).to eq 1
    end

    it "replaces the selection" do
      line = buffer "hello"
      line.move_to 0
      line.select_to 4
      line.insert "j"

      expect(line.text).to eq "jo"
    end
  end

  describe "deleting" do
    it "takes one cluster back, not one code point" do
      line = buffer "a\u{1F1FA}\u{1F1F8}"
      line.delete_backward

      expect(line.text).to eq "a"
    end

    it "takes the selection when there is one" do
      line = buffer "hello"
      line.move_to 1
      line.select_to 4
      line.delete_backward

      expect(line.text).to eq "ho"
      expect(line.cursor).to eq 1
    end

    it "does nothing at either end" do
      line = buffer "a"
      line.move_to 0
      line.delete_backward
      line.move_to 1
      line.delete_forward

      expect(line.text).to eq "a"
    end
  end

  describe "words" do
    it "moves back over the space and then the word" do
      line = buffer "one two three"
      line.move_end
      line.move_word_left

      expect(line.cursor).to eq 8
    end

    it "moves forward to the end of the next word" do
      line = buffer "one two"
      line.move_to 0
      line.move_word_right

      expect(line.cursor).to eq 3
    end

    it "takes what counts as a word from the setting" do
      line = buffer "a-b c"
      line.word = ->(cluster : String) { cluster != " " }
      line.move_end
      line.move_word_left
      line.move_word_left

      expect(line.cursor).to eq 0
    end
  end

  describe "killing" do
    it "keeps what it took for the yank" do
      line = buffer "hello world"
      line.move_to 6
      line.kill_to_end
      line.move_to 0
      line.yank

      expect(line.text).to eq "worldhello "
    end

    # Three presses take three words and give them back the way round they
    # were, which is the whole point of gathering.
    it "gathers consecutive backward kills in order" do
      line = buffer "one two three"
      line.move_end
      line.kill_word_backward
      line.kill_word_backward

      expect(line.killed).to eq "two three"
      expect(line.text).to eq "one "
    end

    it "gathers consecutive forward kills in order" do
      line = buffer "one two three"
      line.move_to 0
      line.kill_word_forward
      line.kill_word_forward

      expect(line.killed).to eq "one two"
    end

    it "starts again when something else happens in between" do
      line = buffer "one two"
      line.move_end
      line.kill_word_backward
      line.move_left
      line.kill_word_backward

      expect(line.killed).to eq "one"
    end
  end

  describe "selection" do
    it "keeps the anchor where the selection started" do
      line = buffer "hello"
      line.move_to 1
      line.select_to 4

      expect(line.selection).to eq 1...4
      expect(line.selected_text).to eq "ell"
    end

    it "reads the same selected backwards" do
      line = buffer "hello"
      line.move_to 4
      line.select_to 1

      expect(line.selected_text).to eq "ell"
    end

    it "drops the selection when a plain motion happens" do
      line = buffer "hello"
      line.move_to 1
      line.select_to 4
      line.move_left

      expect(line.selection).to be_nil
    end

    it "has nothing selected once the ends meet" do
      line = buffer "hello"
      line.move_to 2
      line.select_to 4
      line.select_to 2

      expect(line.selection).to be_nil
    end
  end

  describe "lines" do
    it "finds the ends of the line the cursor is on" do
      line = buffer "one\ntwo\nthree"
      line.move_to 5

      expect(line.line_start).to eq 4
      expect(line.line_end).to eq 7
      expect(line.line_index).to eq 1
    end

    it "measures the column from the start of the line" do
      line = buffer "one\n漢b"
      line.move_end

      expect(line.column).to eq 3
    end
  end

  describe "#transpose" do
    it "swaps the two clusters around the cursor" do
      line = buffer "ab"
      line.move_to 1
      line.transpose

      expect(line.text).to eq "ba"
      expect(line.cursor).to eq 2
    end

    it "swaps the last two when the cursor is at the end" do
      line = buffer "abc"
      line.move_end
      line.transpose

      expect(line.text).to eq "acb"
    end
  end

  # The properties worth asserting are the ones that catch a class of bug
  # rather than a case.
  describe "properties" do
    it "leaves the text unchanged when an insert is taken back" do
      random = Random.new 20260825

      12.times do
        line = buffer mixed(random, 20)
        before = line.text
        line.move_to random.rand line.size + 1

        added = mixed random, 3
        line.insert added
        TermBuf::LineBuffer.new(added).size.times { line.delete_backward }

        expect(line.text).to eq before
      end
    end

    it "never puts the cursor inside a cluster" do
      random = Random.new 20260826

      12.times do
        text = mixed random, 20
        line = buffer text
        clusters = TermBuf::Unicode.graphemes text

        expect(line.size).to eq clusters.size

        (0..line.size).each do |index|
          line.move_to index
          expect(line.slice 0...index).to eq clusters.first(index).join
        end
      end
    end

    it "reports a column equal to the widths to its left" do
      random = Random.new 20260827

      12.times do
        line = buffer mixed(random, 20).delete('\n')

        (0..line.size).each do |index|
          line.move_to index
          expect(line.column).to eq TermBuf::Unicode.string_width(line.slice 0...index)
        end
      end
    end

    it "keeps what it deleted, so a yank puts it back" do
      random = Random.new 20260828

      12.times do
        line = buffer mixed(random, 20).delete('\n')
        before = line.text
        line.move_to random.rand line.size + 1
        line.kill_to_end
        line.yank

        expect(line.text).to eq before
      end
    end
  end
end
