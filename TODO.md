# high-level TODOs for termbuf

* [ ] Mouse input support as a separate shard?
  + Is this a good idea? Or should it be a part of the input shard?
* [ ] Extract input support into a separate shard that depends on termbuf for output and event infra
  + [ ] Allow consumer to easily enable app-wide support for CTRL-L to repaint
  + [ ] Input line widget that scrolls horizontally for overflow
  + [ ] Input area widget that can optionally expand horizontally and/or vertically
  + [ ] Arrow key support for cursor movement
  + [ ] Optional mouse movement and selection support if/when mouse support is implemented
  + [ ] Markdown support for text areas?
* [ ] Create a widget shard that uses termbuf underneath
  + [ ] Migrate input widget to this shard from termbuf itself
  + [ ] Full panel layout support
    - [ ] Define minimum, maximum dimensions as absolutes or percentages
    - [ ] Optional panel refresh callback for when they are resized
    - [ ] Support padding, margins, and decorations
      * Decorations might be a 9-slice-style border definition or scroll bar thumb. (What else?)
    - [ ] Optional image foreground or background, where supported
  + [ ] Navigation bar
  + [ ] Drop-down menus
  + [ ] Popovers
  + [ ] Dialogs
  + [ ] Images (when supported)
  + [ ] Disclosure
  + [ ] Button
  + [ ] Button Group
  + [ ] Checkbox
  + [ ] Checkbox Group
  + [ ] Combobox
  + [ ] Copy Button
  + [ ] Data Grid
  + [ ] Date Display/Picker
  + [ ] Calendar
  + [ ] Divider
  + [ ] Drawer
  + [ ] File Display/Picker
  + [ ] Bytes Display
  + [ ] Formatted Number
  + [ ] Icon (emoji, or image when available)
  + [ ] Pagination Control
  + [ ] Progress Bar
  + [ ] QR Code
  + [ ] Rating (★★★☆☆ for example)
  + [ ] Clock
  + [ ] Relative Time
  + [ ] Scrollable Panel
  + [ ] List Selector (move items from left panel to right panel)
  + [ ] Keyword List (autocomplete keywords, turn them to slugs, allow selection and deleting of
        existing slugs)
  + [ ] Selection List (vertical list of labels, returns associated values, can limit number of
        simultaneous selections)
  + [ ] Spinner (when activated, shows activity at a specified or default framerate)
  + [ ] Tabbed Panels (each sub-panel provides a title that shows in the tab bar)
  + [ ] Toast (brief, non-blocking notification that appears in a corner, can stack up, disappear
        after configured display time)
  + [ ] Tree (displays hierarchical data like file system trees or organization charts)
  + [ ] Link (shows a URL, clickable when supported by the terminal, shows full URL in popup when
        selected, can copy URL as well)
  + [ ] Charts
    - [ ] Bar
    - [ ] Sparkline
    - [ ] Single Value (color-coded)
    - [ ] Box Plot
    - [ ] Time Series
    - [ ] Breadcrumbs
    - [ ] Scatter?
  + [ ] Animation
    - Implement CSS-style animations where a widget's properties can be modified over time
    - This could include cycling foreground/background colors on text or a panel through a specified
      list
  + [ ] Gradients
    - Allow a panel to specify default color gradients for foreground/background colors. Text with
      either set overrides, but otherwise, gradients are calculated and applied to 'default' values.
* [ ] Create a web terminal shard
  + [ ] Use ghostty's javascript implementation to serve a terminal interface
  + [ ] No app changes required to support it
  + [ ] Accepts optional 'title' to use, otherwise defaults to program name
  + [ ] Optional embedding support
    - App provides an HTML fragment with a placeholder for the terminal itself, and receive
      HTTP::Server context objects for requests from the client; for example, allowing a console
      game to be played and put its current score into the title, or to play a soundtrack.
