# UI Modes and Rendering in Niffler

## Available UI Modes

### 1. Basic CLI (`--simple`)
Simple terminal interface with basic I/O

### 2. Enhanced UI (`enhanced.nim`)
illwill-based interface with markdown rendering and streaming

### 3. TUI Widget Mode (`--tui` - NEW!)
Clean widget-style interface inspired by tui_widget concepts

## Current Enhanced UI Implementation

**✅ Already has basic markdown rendering** in `src/ui/enhanced.nim:178-280`:

- **Headers**: H1 (`#`), H2 (`##`), H3 (`###`) with different colors and symbols
- **Inline formatting**: Bold (`**text**`), italic (`*text*`), inline code (`` `code` ``)
- **Links**: `[text](url)` display (shows text part only)
- **Lists**: Bullet lists (`-`, `*`) and numbered lists
- **Code blocks**: ``` delimiter detection

The implementation uses `illwill` for terminal control with ANSI colors and styling.

## Recommended Nim Libraries for Enhancement

### Markdown Parsing Libraries

1. **`nim-markdown`** - Most mature option
   - CommonMark and GFM support
   - Extension system for custom features
   - Installation: `nimble install markdown`

2. **`nmark`** - Performance-focused
   - ~4x faster than nim-markdown
   - CommonMark-based but not fully spec-compliant yet

### Diff Rendering Libraries

1. **`hldiff`** - Perfect for git-style diffs
   - Ports Python's difflib with ~100x performance improvement
   - Colored terminal output with customizable ANSI/SGR escapes
   - Git diff compatibility: `git diff | hldiff`
   - Installation: `nimble install hldiff`

2. **Built-in `std/terminal`** - Basic colored output
   - Already used in Niffler's current implementation
   - Provides foreground/background colors and text styles

## Current Status Summary

**✅ What's already implemented:**
- Basic markdown rendering with illwill
- Colored terminal output
- Text styling (bold, italic, code, headers, lists)

**🔧 Potential improvements:**
- Replace basic regex-based markdown with `nim-markdown` for better spec compliance
- Add `hldiff` for proper diff rendering in tool outputs
- Enhanced syntax highlighting for code blocks

## Implementation Details

The enhanced UI in `src/ui/enhanced.nim` includes:

- `renderInlineMarkdown()` - Handles bold, italic, code, links
- `renderMarkdownLine()` - Handles headers, lists, code blocks
- `updateResponseArea()` - Main display logic with markdown rendering
- Color scheme using illwill's color constants (fgYellow, fgGreen, fgCyan, etc.)

The current implementation provides a solid foundation for markdown rendering in terminal applications, with room for enhancement using dedicated parsing libraries.

## New TUI Widget Mode (`enhanced_tui.nim`)

**✅ Features:**
- Clean widget-like interface using pure illwill
- Proper input box at the bottom with borders
- Status bar showing connection status and model info  
- Title bar with helpful hints
- Streaming response support
- History navigation with arrow keys
- Auto-scrolling response display
- Better visual separation of UI elements

**Usage:**
```bash
niffler --tui    # Use TUI widget-style interface
niffler -t       # Short form
```

**Design Benefits:**
- Cleaner visual layout than basic enhanced UI
- More responsive to streaming content
- Better organized screen real estate
- Widget-style approach inspired by tui_widget but using pure illwill
- Fallback hierarchy: TUI → Enhanced → Basic CLI