require "../spec_helper"

private alias Action = TermBuf::Editor::Action
private alias Outcome = TermBuf::Editor::Outcome
private alias Mods = TermBuf::Modifiers
private alias Name = TermBuf::Key::Name

private def editor(text : String = "", **options) : TermBuf::Editor
  made = TermBuf::Editor.new(**options)
  made.text = text
  made
end

private def type(editor : TermBuf::Editor, text : String) : Outcome
  outcome = Outcome::Continue
  text.each_char { |char| outcome = editor.handle TermBuf::Key.character(char) }
  outcome
end

private def press(editor : TermBuf::Editor, name : Name,
                  modifiers : Mods = Mods::None) : Outcome
  editor.handle TermBuf::Key.named(name, modifiers)
end

private def chord(editor : TermBuf::Editor, char : Char,
                  modifiers : Mods = Mods::Ctrl) : Outcome
  editor.handle TermBuf::Key.character(char, modifiers)
end

Spectator.describe TermBuf::Editor do
  describe "typing" do
    it "inserts a character that is bound to nothing" do
      made = editor
      type made, "abc"

      expect(made.text).to eq "abc"
    end

    it "inserts a shifted character" do
      made = editor
      made.handle TermBuf::Key.character('A', Mods::Shift)

      expect(made.text).to eq "A"
    end

    it "ignores a chord that is bound to nothing" do
      made = editor "x"
      chord made, 'q'

      expect(made.text).to eq "x"
    end
  end

  describe "the default bindings" do
    it "moves the way readline does" do
      made = editor "hello"
      chord made, 'a'
      expect(made.buffer.cursor).to eq 0

      chord made, 'e'
      expect(made.buffer.cursor).to eq 5

      chord made, 'b'
      expect(made.buffer.cursor).to eq 4
    end

    it "kills to the end and yanks it back" do
      made = editor "hello world"
      made.buffer.move_to 6
      chord made, 'k'
      expect(made.text).to eq "hello "

      chord made, 'a'
      chord made, 'y'
      expect(made.text).to eq "worldhello "
    end

    it "takes a word back" do
      made = editor "one two"
      chord made, 'w'

      expect(made.text).to eq "one "
    end

    it "moves by word with alt and with ctrl" do
      made = editor "one two"
      chord made, 'b', Mods::Alt
      expect(made.buffer.cursor).to eq 4

      press made, Name::Right, Mods::Ctrl
      expect(made.buffer.cursor).to eq 7
    end

    it "extends a selection with shift" do
      made = editor "hello"
      made.buffer.move_to 0
      press made, Name::Right, Mods::Shift
      press made, Name::Right, Mods::Shift

      expect(made.buffer.selected_text).to eq "he"
    end
  end

  describe "outcomes" do
    it "hands the line over and clears it" do
      made = editor "typed"

      expect(press made, Name::Enter).to eq Outcome::Accepted
      expect(made.accepted).to eq "typed"
      expect(made.text).to be_empty
    end

    it "says when the line was abandoned" do
      expect(chord editor("typed"), 'c').to eq Outcome::Cancelled
    end

    # Ctrl+D means end of input on an empty line and forward delete on one with
    # anything in it. An application has to be able to tell those apart.
    it "ends input only on an empty line" do
      made = editor "ab"
      made.buffer.move_to 0

      expect(chord made, 'd').to eq Outcome::Continue
      expect(made.text).to eq "b"

      made.text = ""
      expect(chord made, 'd').to eq Outcome::Ended
    end
  end

  describe "history" do
    it "walks back through what was accepted" do
      made = editor history: TermBuf::History.new
      type made, "first"
      press made, Name::Enter
      type made, "second"
      press made, Name::Enter

      press made, Name::Up
      expect(made.text).to eq "second"

      press made, Name::Up
      expect(made.text).to eq "first"

      press made, Name::Down
      expect(made.text).to eq "second"
    end

    it "keeps the line being typed" do
      made = editor history: TermBuf::History.new
      type made, "stored"
      press made, Name::Enter
      type made, "half"

      press made, Name::Up
      expect(made.text).to eq "stored"

      press made, Name::Down
      expect(made.text).to eq "half"
    end

    # Stepping back onto an entry that has been edited would lose the edit.
    it "gives up the walk once the line is changed" do
      made = editor history: TermBuf::History.new
      type made, "stored"
      press made, Name::Enter

      press made, Name::Up
      type made, "!"
      press made, Name::Down

      expect(made.text).to eq "stored!"
    end

    it "does not give up the walk for a plain motion" do
      made = editor history: TermBuf::History.new
      type made, "stored"
      press made, Name::Enter

      press made, Name::Up
      chord made, 'a'
      press made, Name::Down

      expect(made.text).to be_empty
    end
  end

  describe "completion" do
    it "inserts the one candidate there is" do
      made = editor completions: ->(_request : TermBuf::Completion::Request) do
        TermBuf::Completion::Result.new ["commit"]
      end
      type made, "com"
      press made, Name::Tab

      expect(made.text).to eq "commit"
      expect(made.listing?).to be_false
    end

    it "inserts as much as the candidates agree on" do
      made = editor completions: ->(_request : TermBuf::Completion::Request) do
        TermBuf::Completion::Result.new ["commit", "commander"]
      end
      type made, "co"
      press made, Name::Tab

      expect(made.text).to eq "comm"
    end

    # Listing on the first press is noise on a line that only ever had one
    # answer, so it takes two.
    it "lists only once the key has been pressed twice" do
      made = editor completions: ->(_request : TermBuf::Completion::Request) do
        TermBuf::Completion::Result.new ["commit", "commander"]
      end
      type made, "co"

      press made, Name::Tab
      expect(made.listing?).to be_false

      press made, Name::Tab
      expect(made.listing?).to be_true
      expect(made.candidates).to eq ["commit", "commander"]
    end

    it "forgets the candidates once anything else happens" do
      made = editor completions: ->(_request : TermBuf::Completion::Request) do
        TermBuf::Completion::Result.new ["commit", "commander"]
      end
      type made, "co"
      press made, Name::Tab
      press made, Name::Tab
      type made, "m"

      expect(made.candidates).to be_empty
      expect(made.listing?).to be_false
    end

    it "tells the hook which word is being completed" do
      seen = nil.as(TermBuf::Completion::Request?)
      made = editor completions: ->(request : TermBuf::Completion::Request) do
        seen = request
        TermBuf::Completion::Result.new [] of String
      end
      type made, "git com"
      press made, Name::Tab

      expect(seen.try &.word).to eq "com"
      expect(seen.try &.text).to eq "git com"
      expect(seen.try &.range).to eq 4...7
    end

    it "does nothing with no hook set" do
      made = editor "x"

      expect(press made, Name::Tab).to eq Outcome::Continue
      expect(made.text).to eq "x"
      expect(made.completion.idle?).to be_true
    end
  end

  # Without this an application cannot tell a completion that found nothing
  # from one that was never asked for, and a key that appears to do nothing is
  # the result.
  describe "what a completion came to" do
    private def colours(*names : String)
      ->(request : TermBuf::Completion::Request) do
        TermBuf::Completion::Result.new names.to_a.select(&.starts_with? request.word)
      end
    end

    it "is idle before anything is asked" do
      expect(editor.completion.idle?).to be_true
    end

    it "says nothing was found" do
      made = editor completions: colours("amber", "azure")
      type made, "zzz"
      press made, Name::Tab

      expect(made.completion.nothing?).to be_true
      expect(made.candidates).to be_empty
      expect(made.text).to eq "zzz"
    end

    it "stays saying so while the key is pressed again" do
      made = editor completions: colours("amber")
      type made, "zzz"
      press made, Name::Tab
      press made, Name::Tab

      expect(made.completion.nothing?).to be_true
    end

    it "says one candidate went in" do
      made = editor completions: colours("scarlet", "teal")
      type made, "sc"
      press made, Name::Tab

      expect(made.completion.inserted?).to be_true
      expect(made.text).to eq "scarlet"
    end

    it "says there were choices before it says it is listing them" do
      made = editor completions: colours("carmine", "cobalt", "crimson")
      type made, "c"

      press made, Name::Tab
      expect(made.completion.choices?).to be_true
      expect(made.listing?).to be_false

      press made, Name::Tab
      expect(made.completion.listing?).to be_true
      expect(made.listing?).to be_true
    end

    it "starts over at choices after a single candidate went in" do
      calls = 0
      made = editor completions: ->(_request : TermBuf::Completion::Request) do
        calls += 1
        TermBuf::Completion::Result.new calls == 1 ? ["one"] : ["alpha", "amber"]
      end
      type made, "a"

      press made, Name::Tab
      expect(made.completion.inserted?).to be_true

      # Several to choose from now. The press after an insertion must not jump
      # straight to a list, having never offered the choice once.
      press made, Name::Tab
      expect(made.completion.choices?).to be_true
    end

    it "goes back to idle at the next edit" do
      made = editor completions: colours("amber")
      type made, "zzz"
      press made, Name::Tab
      expect(made.completion.nothing?).to be_true

      type made, "x"
      expect(made.completion.idle?).to be_true
    end
  end

  describe "paste" do
    it "goes in as text rather than as key presses" do
      made = editor
      made.paste "q\tsomething"

      expect(made.text).to eq "q\tsomething"
    end

    it "flattens line breaks where there is no room for them" do
      made = editor
      made.paste "one\ntwo"

      expect(made.text).to eq "one two"
    end

    it "keeps them where there is" do
      made = editor multiline: true
      made.paste "one\ntwo"

      expect(made.text).to eq "one\ntwo"
    end
  end

  describe "rebinding" do
    it "takes an entry replaced in the keymap" do
      made = editor "hello"
      made.keymap[TermBuf::Key.character 'k', Mods::Ctrl] = Action::KillToStart
      made.buffer.move_to 3
      chord made, 'k'

      expect(made.text).to eq "lo"
    end
  end
end
