require "../unicode/grapheme"

module TermBuf
  # Editable text and a cursor, in grapheme clusters.
  #
  # A cluster is what a cursor moves over and what occupies a cell, so it is
  # what this counts in. Every index here is a cluster index, from zero to
  # `#size`, and the cursor sits between clusters rather than on one. Nothing
  # in here knows about terminals, drawing, or keys; `Editor` binds keys to it
  # and `Field` draws it.
  #
  # Widths come from a `Unicode::WidthPolicy`, which has to be the one the
  # terminal was measured with or the column this reports is not the column the
  # cursor lands in.
  class LineBuffer
    # One cluster and the cells it takes, measured once when it goes in.
    private record Piece, text : String, width : Int32

    # What counts as part of a word, for the motions and deletions that move by
    # one. A shell, a search box, and an expression evaluator disagree, so this
    # is replaceable.
    property word : Proc(String, Bool)

    # How clusters are measured, which has to be the policy the terminal was
    # measured with or the column reported here is not the one the cursor lands
    # in.
    getter policy : Unicode::WidthPolicy

    # Where the next cluster goes, between zero and `#size`.
    getter cursor : Int32 = 0

    # Where a selection started, or `nil` when nothing is selected. The cursor
    # is the other end.
    getter anchor : Int32? = nil

    @pieces : Array(Piece)

    # What the last kill took, which `#yank` puts back.
    getter killed : String = ""

    # Whether the last thing done was a kill, so that consecutive kills gather
    # into one rather than each replacing the last.
    @killing = false

    def initialize(text : String = "",
                   @policy : Unicode::WidthPolicy = Unicode::WidthPolicy::DEFAULT)
      @pieces = [] of Piece
      @word = DEFAULT_WORD
      replace text
    end

    # Alphanumerics and the underscore, which is what readline means by a word.
    DEFAULT_WORD = ->(cluster : String) do
      char = cluster[0]?
      return false unless char

      char.alphanumeric? || char == '_'
    end

    # ------------------------------------------------------------- reading

    # Clusters, not characters and not bytes.
    def size : Int32
      @pieces.size
    end

    # Whether there is nothing to edit.
    def empty? : Bool
      @pieces.empty?
    end

    # Everything, as one string.
    def text : String
      String.build { |io| @pieces.each { |piece| io << piece.text } }
    end

    # The cluster at *index*, or `nil` past either end.
    def [](index : Int32) : String?
      piece = @pieces[index]?
      piece.try &.text
    end

    # The text of a range of clusters.
    def slice(range : Range(Int32, Int32)) : String
      String.build do |io|
        range.each { |index| @pieces[index]?.try { |piece| io << piece.text } }
      end
    end

    # Cells between the start of the cursor's line and the cursor. What a
    # caller needs to put the terminal's own cursor in the right place.
    def column : Int32
      width_between line_start, @cursor
    end

    # Cells the whole text takes, ignoring line breaks.
    def width : Int32
      width_between 0, size
    end

    # Cells between two cluster indices.
    def width_between(from : Int32, to : Int32) : Int32
      total = 0
      (Math.max(from, 0)...Math.min(to, size)).each { |index| total += @pieces[index].width }
      total
    end

    # Cells the cluster at *index* takes.
    def width_at(index : Int32) : Int32
      piece = @pieces[index]?
      piece ? piece.width : 0
    end

    # ------------------------------------------------------------- writing

    # Throws away everything and starts again with *text*, cursor at the end.
    # What history recall does.
    def replace(text : String) : Nil
      @pieces.clear
      @anchor = nil
      @killing = false
      append text
      @cursor = size
    end

    # Empties it.
    def clear : Nil
      replace ""
    end

    # Inserts *text* at the cursor, replacing the selection if there is one.
    def insert(text : String) : Nil
      delete_selection
      @killing = false
      return if text.empty?

      added = segment text
      # Splicing an array in, which `Array#insert` only does one element at a
      # time.
      @pieces = @pieces[0, @cursor] + added + @pieces[@cursor..]
      @cursor += added.size
    end

    # :ditto:
    def insert(char : Char) : Nil
      insert char.to_s
    end

    private def append(text : String) : Nil
      segment(text).each { |piece| @pieces << piece }
    end

    private def segment(text : String) : Array(Piece)
      pieces = [] of Piece

      Unicode.each_grapheme text, @policy do |grapheme|
        pieces << Piece.new grapheme.text(text), grapheme.width
      end

      pieces
    end

    # ------------------------------------------------------------ deleting

    # Removes the cluster before the cursor, or the selection if there is one.
    def delete_backward : Nil
      return if delete_selection
      return if @cursor.zero?

      @killing = false
      @cursor -= 1
      @pieces.delete_at @cursor
    end

    # Removes the cluster after the cursor, or the selection if there is one.
    def delete_forward : Nil
      return if delete_selection
      return if @cursor >= size

      @killing = false
      @pieces.delete_at @cursor
    end

    # Removes *range* and puts the cursor where it started. Returns what it
    # took.
    def delete(range : Range(Int32, Int32)) : String
      @killing = false
      from = Math.max range.begin, 0
      to = Math.min range.end, size
      return "" if to <= from

      taken = slice from...to
      @pieces.delete_at from, to - from
      @cursor = from
      @anchor = nil
      taken
    end

    # Removes what is selected. Returns whether anything was.
    def delete_selection : Bool
      range = selection
      return false unless range

      @killing = false
      delete range
      true
    end

    # ----------------------------------------------------------- killing

    # Removes from the cursor to the end of the line, keeping it for `#yank`.
    def kill_to_end : Nil
      kill @cursor...line_end, backward: false
    end

    # Removes from the start of the line to the cursor, keeping it for `#yank`.
    def kill_to_start : Nil
      kill line_start...@cursor, backward: true
    end

    # Removes the word before the cursor, keeping it for `#yank`.
    def kill_word_backward : Nil
      kill word_left...@cursor, backward: true
    end

    # Removes the word after the cursor, keeping it for `#yank`.
    def kill_word_forward : Nil
      kill @cursor...word_right, backward: false
    end

    # Puts back what the last kill took.
    def yank : Nil
      return if @killed.empty?

      insert @killed
    end

    # Consecutive kills gather rather than each replacing the last, which is
    # what makes three presses of the same key take three words and give them
    # all back in the order they were in. Anything else between two kills ends
    # the gathering, which is what `@killing` is cleared by.
    private def kill(range : Range(Int32, Int32), backward : Bool) : Nil
      gathering = @killing
      taken = delete range
      return if taken.empty?

      @killed = if !gathering
                  taken
                elsif backward
                  taken + @killed
                else
                  @killed + taken
                end
      @killing = true
    end

    # ------------------------------------------------------------- motion

    # Moves the cursor to *index*, clamped, and drops any selection.
    def move_to(index : Int32) : Nil
      @cursor = index.clamp 0, size
      @anchor = nil
      @killing = false
    end

    # Moves the cursor to *index* keeping the anchor where it is, which is what
    # a shift-modified motion does.
    def select_to(index : Int32) : Nil
      @anchor ||= @cursor
      @cursor = index.clamp 0, size
      @killing = false
      @anchor = nil if @anchor == @cursor
    end

    # One cluster left.
    def move_left : Nil
      move_to @cursor - 1
    end

    # One cluster right.
    def move_right : Nil
      move_to @cursor + 1
    end

    # To the start of the line the cursor is on.
    def move_home : Nil
      move_to line_start
    end

    # To the end of the line the cursor is on.
    def move_end : Nil
      move_to line_end
    end

    # Back over one word, and the space before it.
    def move_word_left : Nil
      move_to word_left
    end

    # Forward to the end of the next word.
    def move_word_right : Nil
      move_to word_right
    end

    # Where the cursor would land moving one word left: back over anything that
    # is not a word, then back over the word.
    def word_left : Int32
      index = @cursor

      while index > 0 && !word_at? index - 1
        index -= 1
      end

      while index > 0 && word_at? index - 1
        index -= 1
      end

      index
    end

    # :ditto:
    def word_right : Int32
      index = @cursor

      while index < size && !word_at? index
        index += 1
      end

      while index < size && word_at? index
        index += 1
      end

      index
    end

    private def word_at?(index : Int32) : Bool
      piece = @pieces[index]?
      piece ? @word.call(piece.text) : false
    end

    # ---------------------------------------------------------------- lines

    NEWLINE = "\n"

    # Start of the line the cursor is on.
    def line_start : Int32
      index = @cursor

      while index > 0 && @pieces[index - 1].text != NEWLINE
        index -= 1
      end

      index
    end

    # End of the line the cursor is on, before the break.
    def line_end : Int32
      index = @cursor

      while index < size && @pieces[index].text != NEWLINE
        index += 1
      end

      index
    end

    # Which line the cursor is on, counting from zero.
    def line_index : Int32
      (0...@cursor).count { |index| @pieces[index].text == NEWLINE }
    end

    # The text split on its line breaks.
    def lines : Array(String)
      text.split NEWLINE
    end

    # ------------------------------------------------------------ selection

    # The selected clusters, or `nil` when nothing is selected.
    def selection : Range(Int32, Int32)?
      anchor = @anchor
      return unless anchor && anchor != @cursor

      anchor < @cursor ? anchor...@cursor : @cursor...anchor
    end

    # What is selected, or an empty string when nothing is.
    def selected_text : String
      range = selection
      range ? slice(range) : ""
    end

    # Whether anything is selected.
    def selected? : Bool
      !selection.nil?
    end

    # Drops the selection, leaving the cursor where it is.
    def collapse : Nil
      @anchor = nil
    end

    # Selects everything, leaving the cursor at the end.
    def select_all : Nil
      @anchor = 0
      @cursor = size
    end

    # Swaps the two clusters around the cursor, which is what `Ctrl+T` does.
    def transpose : Nil
      return if size < 2

      @killing = false
      index = @cursor >= size ? size - 1 : @cursor
      return if index.zero?

      @pieces.swap index - 1, index
      @cursor = Math.min index + 1, size
      @anchor = nil
    end

    def to_s(io : IO) : Nil
      io << "LineBuffer(" << text.inspect << " cursor=" << @cursor << ')'
    end
  end
end
