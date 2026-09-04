module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # Ways a terminal departs from what the escape sequences it accepts imply.
  #
  # Kept apart from `Capability`, which answers what a terminal can do. This
  # answers what it gets wrong, and mixing the two makes both harder to read: a
  # capability turned off means an application should not ask, where a quirk
  # means it should ask and then cope with the answer.
  #
  # Named for the behaviour rather than for a terminal, so that mapping another
  # terminal onto one is a row in a table once somebody measures it.
  @[Flags]
  enum Quirk
    # The terminal counts a grapheme cluster's columns by summing its code
    # points instead of measuring the cluster.
    #
    # Terminal.app does this. `👨‍👩‍👧‍👦` is four emoji of two columns and three
    # joiners of one, so it owns eleven columns; `क्षि` owns three; `☺️` owns
    # one, since the variation selector is a nonspacing mark. That count is
    # what `CPR` reports and what `CUP` addresses — forcing a character to
    # column three of a row starting with the family tears the cluster into
    # `👨X👪`, which cannot be done to a two column glyph.
    #
    # It draws the composed glyph anyway, at the width the glyph wants, and
    # slides the rest of the row left to sit flush against it. So a row holding
    # such a cluster has everything after it out of step with every other row,
    # by the difference between the columns the cluster owns and the columns it
    # is painted in. The same difference the other way — `☺️` owning one column
    # and painted across two — puts the glyph on top of its neighbour.
    #
    # Nothing here lays such a row out correctly. `Terminal` watches for the
    # first cluster this happens to and says so; see `Terminal#warn_composed_drift?`.
    PerCodePointColumns
  end
end
