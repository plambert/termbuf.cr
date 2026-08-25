require "../spec_helper"

Spectator.describe TermBuf::History do
  describe "#add" do
    it "keeps entries newest last" do
      history = TermBuf::History.new
      history.add "one"
      history.add "two"

      expect(history.entries).to eq ["one", "two"]
    end

    it "ignores a blank line" do
      history = TermBuf::History.new
      history.add "   "

      expect(history).to be_empty
    end

    # A history full of the same command is a history of one command.
    it "ignores a line identical to the one before it" do
      history = TermBuf::History.new
      history.add "ls"
      history.add "ls"

      expect(history.size).to eq 1
    end

    it "drops the oldest once it is full" do
      history = TermBuf::History.new capacity: 2
      history.add "one"
      history.add "two"
      history.add "three"

      expect(history.entries).to eq ["two", "three"]
    end
  end

  describe "walking" do
    it "steps back through the entries newest first" do
      history = TermBuf::History.new
      history.add "one"
      history.add "two"

      expect(history.previous "").to eq "two"
      expect(history.previous "").to eq "one"
      expect(history.previous "").to be_nil
    end

    # The line being typed when the walk starts is the thing every other
    # implementation loses.
    it "gives back the line that was being typed" do
      history = TermBuf::History.new
      history.add "stored"

      expect(history.previous "half typed").to eq "stored"
      expect(history.next).to eq "half typed"
      expect(history.walking?).to be_false
    end

    it "goes nowhere forward when no walk is under way" do
      history = TermBuf::History.new
      history.add "one"

      expect(history.next).to be_nil
    end

    it "starts again after a reset" do
      history = TermBuf::History.new
      history.add "one"
      history.previous "typing"
      history.reset

      expect(history.previous "different").to eq "one"
      expect(history.next).to eq "different"
    end
  end

  describe "prefix search" do
    it "visits only the entries beginning with what was typed" do
      history = TermBuf::History.new search: TermBuf::History::Search::Prefix
      history.add "git status"
      history.add "ls -l"
      history.add "git commit"

      expect(history.previous "git").to eq "git commit"
      expect(history.previous "git").to eq "git status"
      expect(history.previous "git").to be_nil
    end

    # Recalling an entry must not change what is being searched for, or the
    # second step back searches for the first result.
    it "keeps searching for what was typed, not for what was recalled" do
      history = TermBuf::History.new search: TermBuf::History::Search::Prefix
      history.add "git status"
      history.add "git commit"

      first = history.previous "git"
      fail "nothing was recalled" unless first

      expect(history.previous first).to eq "git status"
    end

    it "visits everything when nothing was typed" do
      history = TermBuf::History.new search: TermBuf::History::Search::Prefix
      history.add "one"
      history.add "two"

      expect(history.previous "").to eq "two"
      expect(history.previous "").to eq "one"
    end
  end

  describe "storage" do
    it "writes and reads one entry per line" do
      history = TermBuf::History.new
      history.add "one"
      history.add "two"

      written = IO::Memory.new
      history.save written

      restored = TermBuf::History.new
      restored.load IO::Memory.new(written.to_s)

      expect(restored.entries).to eq ["one", "two"]
    end

    it "keeps only the newest when the file is longer than the capacity" do
      history = TermBuf::History.new capacity: 2
      history.load IO::Memory.new("one\ntwo\nthree\n")

      expect(history.entries).to eq ["two", "three"]
    end
  end
end

Spectator.describe TermBuf::Completion do
  describe ".common_prefix" do
    it "is the whole thing when there is one candidate" do
      expect(described_class.common_prefix ["commit"]).to eq "commit"
    end

    it "is as much as can be inserted without choosing" do
      expect(described_class.common_prefix ["commit", "commander"]).to eq "comm"
    end

    it "is empty when they start differently" do
      expect(described_class.common_prefix ["push", "commit"]).to eq ""
    end

    it "is empty when there is nothing to complete" do
      expect(described_class.common_prefix [] of String).to eq ""
    end

    it "stops at the shortest candidate" do
      expect(described_class.common_prefix ["co", "commit"]).to eq "co"
    end
  end
end
