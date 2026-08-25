require "../input/key"
require "./completion"
require "./history"
require "./line_buffer"

module TermBuf
  # Keys, bound to what they do to a `LineBuffer`.
  #
  # Bindings are data. `Action` names the vocabulary and `Keymap` maps keys to
  # it, so an application rebinds by replacing entries rather than by
  # subclassing, and the enum is what documents what a field can be asked to
  # do.
  #
  # Anything not in the map that carries no modifier but shift is text and gets
  # inserted. That rule is what keeps the map small.
  class Editor
    # Everything a key can be bound to.
    enum Action
      MoveLeft
      MoveRight
      MoveWordLeft
      MoveWordRight
      MoveHome
      MoveEnd

      SelectLeft
      SelectRight
      SelectWordLeft
      SelectWordRight
      SelectHome
      SelectEnd
      SelectAll

      DeleteBackward
      DeleteForward
      DeleteWordBackward
      DeleteWordForward

      KillToEnd
      KillToStart
      Yank
      Transpose

      HistoryPrevious
      HistoryNext

      Complete

      # Insert a line break, for a field that has room for one.
      Newline

      # Hand the line over and clear it.
      Accept

      # Give up on the line.
      Cancel

      # There is no more input coming, which is what `Ctrl+D` on an empty line
      # means and what an empty one does not.
      EndOfInput

      Clear
    end

    # What handling a key came to.
    enum Outcome
      # Nothing that concerns the caller.
      Continue

      # The line was accepted; `#accepted` has it.
      Accepted

      # The line was abandoned.
      Cancelled

      # There is no more input coming.
      Ended
    end

    # Which key does what. Replaceable, and replaceable one entry at a time.
    alias Keymap = Hash(Key, Action)

    # The readline bindings, because that is what fingers in a terminal expect.
    DEFAULT_KEYMAP = begin
      map = Keymap.new

      {
        Key::Name::Left      => Action::MoveLeft,
        Key::Name::Right     => Action::MoveRight,
        Key::Name::Home      => Action::MoveHome,
        Key::Name::End       => Action::MoveEnd,
        Key::Name::Backspace => Action::DeleteBackward,
        Key::Name::Delete    => Action::DeleteForward,
        Key::Name::Up        => Action::HistoryPrevious,
        Key::Name::Down      => Action::HistoryNext,
        Key::Name::Tab       => Action::Complete,
        Key::Name::Enter     => Action::Accept,
        Key::Name::Escape    => Action::Cancel,
      }.each { |name, action| map[Key.named name] = action }

      {
        Key::Name::Left  => Action::SelectLeft,
        Key::Name::Right => Action::SelectRight,
        Key::Name::Home  => Action::SelectHome,
        Key::Name::End   => Action::SelectEnd,
      }.each { |name, action| map[Key.named name, Modifiers::Shift] = action }

      {
        Key::Name::Left  => Action::MoveWordLeft,
        Key::Name::Right => Action::MoveWordRight,
      }.each { |name, action| map[Key.named name, Modifiers::Ctrl] = action }

      {
        'a' => Action::MoveHome,
        'e' => Action::MoveEnd,
        'b' => Action::MoveLeft,
        'f' => Action::MoveRight,
        'k' => Action::KillToEnd,
        'u' => Action::KillToStart,
        'w' => Action::DeleteWordBackward,
        'y' => Action::Yank,
        't' => Action::Transpose,
        'p' => Action::HistoryPrevious,
        'n' => Action::HistoryNext,
        'l' => Action::Clear,
        'c' => Action::Cancel,
        'd' => Action::EndOfInput,
        'h' => Action::DeleteBackward,
      }.each { |char, action| map[Key.character char, Modifiers::Ctrl] = action }

      {
        'b' => Action::MoveWordLeft,
        'f' => Action::MoveWordRight,
        'd' => Action::DeleteWordForward,
      }.each { |char, action| map[Key.character char, Modifiers::Alt] = action }

      map
    end

    # The text being edited.
    getter buffer : LineBuffer

    # Which key does what. `DEFAULT_KEYMAP` duplicated unless one was given.
    property keymap : Keymap

    # Lines entered earlier, or `nil` for a field that does not remember.
    property history : History?

    # What to ask when someone presses the completion key, or `nil` for a field
    # that does not complete.
    property completions : Completion::Hook?

    # Whether `Newline` inserts a break rather than being ignored.
    property? multiline : Bool

    # The line the last `Accepted` outcome handed over.
    getter accepted : String = ""

    # Candidates the last completion offered when there was more than one, for
    # a field to list. Emptied by anything else.
    getter candidates = [] of String

    # Whether the candidates are worth showing, which they are only once the
    # completion key has been pressed twice with nothing chosen in between.
    getter? listing : Bool = false

    @completed = false

    def initialize(@buffer : LineBuffer = LineBuffer.new,
                   keymap : Keymap? = nil,
                   @history : History? = nil,
                   @completions : Completion::Hook? = nil,
                   @multiline : Bool = false)
      @keymap = keymap || DEFAULT_KEYMAP.dup
    end

    # The line as it stands.
    def text : String
      @buffer.text
    end

    # Replaces the line and forgets where the history walk had got to.
    def text=(value : String) : String
      @buffer.replace value
      @history.try &.reset
      forget_completion
      value
    end

    # ------------------------------------------------------------- handling

    # Does whatever *key* is bound to, or inserts it when it is bound to
    # nothing and carries a character.
    def handle(key : Key) : Outcome
      action = @keymap[key]?
      return perform action if action
      return Outcome::Continue unless insertable? key

      forget_completion
      @history.try &.reset
      @buffer.insert key.char
      Outcome::Continue
    end

    # Pasted text goes in as text, whatever it contains. A field with no room
    # for a line break flattens them rather than dropping the rest.
    def paste(text : String) : Outcome
      forget_completion
      @history.try &.reset
      @buffer.insert @multiline ? text : text.gsub(/\r\n|[\r\n]/, " ")
      Outcome::Continue
    end

    # A key with nothing but shift held, carrying a character, is text.
    private def insertable?(key : Key) : Bool
      return false unless key.character?
      return false unless (key.modifiers & ~Modifiers::Shift).none?

      key.char >= ' '
    end

    private def perform(action : Action) : Outcome
      forget_completion unless action.complete?

      case action
      when .accept?           then return accept
      when .cancel?           then return Outcome::Cancelled
      when .end_of_input?     then return @buffer.empty? ? Outcome::Ended : delete_forward
      when .complete?         then complete
      when .history_previous? then recall(-1)
      when .history_next?     then recall 1
      else                         edit action
      end

      Outcome::Continue
    end

    private def accept : Outcome
      @accepted = @buffer.text
      @history.try &.add @accepted
      @buffer.clear
      Outcome::Accepted
    end

    private def delete_forward : Outcome
      @buffer.delete_forward
      Outcome::Continue
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def edit(action : Action) : Nil
      touched = true

      case action
      when .move_left?            then @buffer.move_left
      when .move_right?           then @buffer.move_right
      when .move_word_left?       then @buffer.move_word_left
      when .move_word_right?      then @buffer.move_word_right
      when .move_home?            then @buffer.move_home
      when .move_end?             then @buffer.move_end
      when .select_left?          then @buffer.select_to @buffer.cursor - 1
      when .select_right?         then @buffer.select_to @buffer.cursor + 1
      when .select_word_left?     then @buffer.select_to @buffer.word_left
      when .select_word_right?    then @buffer.select_to @buffer.word_right
      when .select_home?          then @buffer.select_to @buffer.line_start
      when .select_end?           then @buffer.select_to @buffer.line_end
      when .select_all?           then @buffer.select_all
      when .delete_backward?      then @buffer.delete_backward
      when .delete_forward?       then @buffer.delete_forward
      when .delete_word_backward? then @buffer.kill_word_backward
      when .delete_word_forward?  then @buffer.kill_word_forward
      when .kill_to_end?          then @buffer.kill_to_end
      when .kill_to_start?        then @buffer.kill_to_start
      when .yank?                 then @buffer.yank
      when .transpose?            then @buffer.transpose
      when .clear?                then @buffer.clear
      when .newline?              then insert_newline
      else                             touched = false
      end

      # A motion does not end a history walk; changing the line does, because
      # stepping back onto an entry that has been edited would lose the edit.
      @history.try &.reset if touched && changes? action
    end

    private def insert_newline : Nil
      @buffer.insert "\n" if @multiline
    end

    private def changes?(action : Action) : Bool
      !action.to_s.starts_with?("Move") && !action.to_s.starts_with?("Select")
    end

    # ------------------------------------------------------------- history

    private def recall(direction : Int32) : Nil
      history = @history
      return unless history

      line = direction < 0 ? history.previous(@buffer.text) : history.next
      return unless line

      @buffer.replace line
    end

    # ---------------------------------------------------------- completion

    # The word under the cursor, by the buffer's own idea of what a word is.
    def word_range : Range(Int32, Int32)
      cursor = @buffer.cursor
      start = cursor

      while start > 0 && @buffer.word.call(@buffer[start - 1] || "")
        start -= 1
      end

      start...cursor
    end

    private def complete : Nil
      hook = @completions
      return unless hook

      range = word_range
      result = hook.call Completion::Request.new(@buffer.text, @buffer.cursor,
        @buffer.slice(range), range)
      return apply_nothing if result.empty?

      apply result, range
    end

    private def apply(result : Completion::Result, fallback : Range(Int32, Int32)) : Nil
      range = result.range || fallback
      prefix = Completion.common_prefix result.candidates

      unless prefix.empty? || prefix == @buffer.slice(range)
        @buffer.delete range
        @buffer.insert prefix
      end

      if result.candidates.size == 1
        forget_completion
        return
      end

      # One press inserts what is common; the second says there was a choice
      # and shows it. Listing on the first press is noise on a line that only
      # ever had one answer.
      @listing = @completed
      @candidates = result.candidates
      @completed = true
    end

    private def apply_nothing : Nil
      @candidates = [] of String
      @listing = false
      @completed = false
    end

    private def forget_completion : Nil
      return unless @completed || @listing

      @candidates = [] of String
      @listing = false
      @completed = false
    end
  end
end
