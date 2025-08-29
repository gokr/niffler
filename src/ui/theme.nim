## Theme System for Terminal Output
##
## Provides configurable theming for markdown rendering and CLI output.
## Supports color and style customization through TOML configuration.

import std/[tables, strutils, options]
import terminal
import ../types/config as configTypes

type
  ThemeStyle* = object
    color*: ForegroundColor
    bgColor*: BackgroundColor
    style*: Style
  
  Theme* = object
    name*: string
    header1*: ThemeStyle
    header2*: ThemeStyle
    header3*: ThemeStyle
    bold*: ThemeStyle
    italic*: ThemeStyle
    code*: ThemeStyle
    link*: ThemeStyle
    listBullet*: ThemeStyle
    codeBlock*: ThemeStyle
    normal*: ThemeStyle
    diffAdded*: ThemeStyle
    diffRemoved*: ThemeStyle
    diffContext*: ThemeStyle
    diffAddedBg*: ThemeStyle      # Background highlight for added content
    diffRemovedBg*: ThemeStyle    # Background highlight for removed content
    diffAddedText*: ThemeStyle    # Text style for added content
    diffRemovedText*: ThemeStyle  # Text style for removed content
    success*: ThemeStyle
    error*: ThemeStyle
    toolCall*: ThemeStyle

# Global theme registry
var themeRegistry*: Table[string, Theme]
var currentTheme*: Theme

proc parseColor*(colorStr: string): ForegroundColor =
  ## Parse color string to ForegroundColor enum
  case colorStr.toLower():
  of "black": fgBlack
  of "red": fgRed
  of "green": fgGreen
  of "yellow": fgYellow
  of "blue": fgBlue
  of "magenta": fgMagenta
  of "cyan": fgCyan
  of "white": fgWhite
  else: fgWhite  # Default fallback

proc parseStyle*(styleStr: string): Style =
  ## Parse style string to Style enum
  case styleStr.toLower():
  of "bright": styleBright
  of "dim": styleDim
  of "italic": styleItalic
  of "underscore": styleUnderscore
  of "blink": styleBlink
  of "reverse": styleReverse
  of "strikethrough": styleStrikethrough
  else: styleBright  # Default fallback

proc parseBgColor*(colorStr: string): BackgroundColor =
  ## Parse background color string to BackgroundColor enum
  case colorStr.toLower():
  of "black": bgBlack
  of "red": bgRed
  of "green": bgGreen
  of "yellow": bgYellow
  of "blue": bgBlue
  of "magenta": bgMagenta
  of "cyan": bgCyan
  of "white": bgWhite
  of "default": bgDefault
  else: bgDefault  # Default fallback

proc createThemeStyle*(color: string, bgColor: string = "default", style: string = "bright"): ThemeStyle =
  ## Create a ThemeStyle from color, background color, and style strings
  ThemeStyle(
    color: parseColor(color),
    bgColor: parseBgColor(bgColor),
    style: parseStyle(style)
  )

proc getDefaultTheme*(): Theme =
  ## Get the default theme with standard terminal colors
  Theme(
    name: "default",
    header1: createThemeStyle("yellow", "default", "bright"),
    header2: createThemeStyle("yellow", "default", "bright"),
    header3: createThemeStyle("yellow", "default", "dim"),
    bold: createThemeStyle("white", "default", "bright"),
    italic: createThemeStyle("cyan", "default", "bright"),
    code: createThemeStyle("green", "default", "dim"),
    link: createThemeStyle("blue", "default", "bright"),
    listBullet: createThemeStyle("white", "default", "bright"),
    codeBlock: createThemeStyle("cyan", "default", "bright"),
    normal: createThemeStyle("white", "default", "bright"),
    diffAdded: createThemeStyle("white", "green", "bright"),           # Light green background for entire added line
    diffRemoved: createThemeStyle("white", "red", "bright"),           # Light red background for entire removed line
    diffContext: createThemeStyle("white", "default", "bright"),
    diffAddedBg: createThemeStyle("green", "green", "bright"),         # Dark green on green for changed portions
    diffRemovedBg: createThemeStyle("red", "red", "bright"),           # Dark red on red for changed portions
    diffAddedText: createThemeStyle("green", "default", "bright"),
    diffRemovedText: createThemeStyle("red", "default", "bright"),
    success: createThemeStyle("green", "default", "bright"),
    error: createThemeStyle("red", "default", "bright"),
    toolCall: createThemeStyle("blue", "default", "bright")
  )

proc getDarkTheme*(): Theme =
  ## Get a theme optimized for dark terminals
  Theme(
    name: "dark",
    header1: createThemeStyle("blue", "default", "bright"),
    header2: createThemeStyle("cyan", "default", "bright"),
    header3: createThemeStyle("cyan", "default", "dim"),
    bold: createThemeStyle("white", "default", "bright"),
    italic: createThemeStyle("yellow", "default", "bright"),
    code: createThemeStyle("green", "default", "bright"),
    link: createThemeStyle("magenta", "default", "bright"),
    listBullet: createThemeStyle("cyan", "default", "bright"),
    codeBlock: createThemeStyle("blue", "default", "dim"),
    normal: createThemeStyle("white", "default", "bright"),
    diffAdded: createThemeStyle("white", "green", "bright"),
    diffRemoved: createThemeStyle("white", "red", "bright"),
    diffContext: createThemeStyle("white", "default", "bright"),
    diffAddedBg: createThemeStyle("black", "green", "bright"),
    diffRemovedBg: createThemeStyle("black", "red", "bright"),
    diffAddedText: createThemeStyle("green", "default", "bright"),
    diffRemovedText: createThemeStyle("red", "default", "bright"),
    success: createThemeStyle("green", "default", "bright"),
    error: createThemeStyle("red", "default", "bright"),
    toolCall: createThemeStyle("cyan", "default", "bright")
  )

proc getLightTheme*(): Theme =
  ## Get a theme optimized for light terminals
  Theme(
    name: "light",
    header1: createThemeStyle("blue", "default", "bright"),
    header2: createThemeStyle("magenta", "default", "bright"),
    header3: createThemeStyle("magenta", "default", "dim"),
    bold: createThemeStyle("black", "default", "bright"),
    italic: createThemeStyle("blue", "default", "dim"),
    code: createThemeStyle("green", "default", "dim"),
    link: createThemeStyle("blue", "default", "bright"),
    listBullet: createThemeStyle("black", "default", "bright"),
    codeBlock: createThemeStyle("magenta", "default", "dim"),
    normal: createThemeStyle("black", "default", "bright"),
    diffAdded: createThemeStyle("black", "green", "bright"),
    diffRemoved: createThemeStyle("black", "red", "bright"),
    diffContext: createThemeStyle("black", "default", "bright"),
    diffAddedBg: createThemeStyle("black", "green", "bright"),
    diffRemovedBg: createThemeStyle("white", "red", "bright"),
    diffAddedText: createThemeStyle("green", "default", "bright"),
    diffRemovedText: createThemeStyle("red", "default", "bright"),
    success: createThemeStyle("green", "default", "bright"),
    error: createThemeStyle("red", "default", "bright"),
    toolCall: createThemeStyle("blue", "default", "bright")
  )

proc getMinimalTheme*(): Theme =
  ## Get a minimal monochrome theme
  Theme(
    name: "minimal",
    header1: createThemeStyle("white", "default", "bright"),
    header2: createThemeStyle("white", "default", "bright"),
    header3: createThemeStyle("white", "default", "dim"),
    bold: createThemeStyle("white", "default", "bright"),
    italic: createThemeStyle("white", "default", "dim"),
    code: createThemeStyle("white", "default", "dim"),
    link: createThemeStyle("white", "default", "underscore"),
    listBullet: createThemeStyle("white", "default", "bright"),
    codeBlock: createThemeStyle("white", "default", "dim"),
    normal: createThemeStyle("white", "default", "bright"),
    diffAdded: createThemeStyle("white", "default", "bright"),
    diffRemoved: createThemeStyle("white", "default", "dim"),
    diffContext: createThemeStyle("white", "default", "bright"),
    diffAddedBg: createThemeStyle("white", "default", "bright"),
    diffRemovedBg: createThemeStyle("white", "default", "dim"),
    diffAddedText: createThemeStyle("white", "default", "bright"),
    diffRemovedText: createThemeStyle("white", "default", "dim"),
    success: createThemeStyle("white", "default", "bright"),
    error: createThemeStyle("white", "default", "dim"),
    toolCall: createThemeStyle("white", "default", "bright")
  )

proc registerTheme*(theme: Theme) =
  ## Register a theme in the global registry
  themeRegistry[theme.name] = theme

proc initializeThemes*() =
  ## Initialize built-in themes
  registerTheme(getDefaultTheme())
  registerTheme(getDarkTheme())
  registerTheme(getLightTheme())
  registerTheme(getMinimalTheme())
  
  # Set default theme
  currentTheme = getDefaultTheme()

proc setCurrentTheme*(themeName: string): bool =
  ## Set the current theme by name, returns true if successful
  if themeName in themeRegistry:
    currentTheme = themeRegistry[themeName]
    return true
  return false

proc getAvailableThemes*(): seq[string] =
  ## Get list of available theme names
  result = @[]
  for themeName in themeRegistry.keys:
    result.add(themeName)

proc formatWithStyle*(text: string, themeStyle: ThemeStyle): string =
  ## Format text with ANSI color codes using theme style
  let colorCode = case themeStyle.color:
    of fgBlack: "\x1b[30m"
    of fgRed: "\x1b[31m"
    of fgGreen: "\x1b[32m"
    of fgYellow: "\x1b[33m"
    of fgBlue: "\x1b[34m"
    of fgMagenta: "\x1b[35m"
    of fgCyan: "\x1b[36m"
    of fgWhite: "\x1b[37m"
    else: "\x1b[37m"  # Default to white
  
  let bgColorCode = case themeStyle.bgColor:
    of bgBlack: "\x1b[40m"
    of bgRed: "\x1b[41m"
    of bgGreen: "\x1b[42m"
    of bgYellow: "\x1b[43m"
    of bgBlue: "\x1b[44m"
    of bgMagenta: "\x1b[45m"
    of bgCyan: "\x1b[46m"
    of bgWhite: "\x1b[47m"
    of bgDefault: ""
    else: ""  # Default to no background color
  
  let styleCode = case themeStyle.style:
    of styleBright: "\x1b[1m"
    of styleDim: "\x1b[2m"
    of styleItalic: "\x1b[3m"
    of styleUnderscore: "\x1b[4m"
    of styleBlink: "\x1b[5m"
    of styleReverse: "\x1b[7m"
    of styleStrikethrough: "\x1b[9m"
    else: "\x1b[1m"  # Default to bright
  
  result = styleCode & colorCode & bgColorCode & text & "\x1b[0m"

proc convertThemeStyleConfig(config: configTypes.ThemeStyleConfig): ThemeStyle =
  ## Convert config ThemeStyleConfig to theme ThemeStyle
  # For now, we'll use default background color for config-based themes
  # In the future, we could extend the config to support background colors
  ThemeStyle(
    color: parseColor(config.color),
    bgColor: bgDefault,
    style: parseStyle(config.style)
  )

proc convertThemeConfig(config: configTypes.ThemeConfig): Theme =
  ## Convert config ThemeConfig to theme Theme
  Theme(
    name: config.name,
    header1: convertThemeStyleConfig(config.header1),
    header2: convertThemeStyleConfig(config.header2),
    header3: convertThemeStyleConfig(config.header3),
    bold: convertThemeStyleConfig(config.bold),
    italic: convertThemeStyleConfig(config.italic),
    code: convertThemeStyleConfig(config.code),
    link: convertThemeStyleConfig(config.link),
    listBullet: convertThemeStyleConfig(config.listBullet),
    codeBlock: convertThemeStyleConfig(config.codeBlock),
    normal: convertThemeStyleConfig(config.normal),
    diffAdded: convertThemeStyleConfig(config.diffAdded),
    diffRemoved: convertThemeStyleConfig(config.diffRemoved),
    diffContext: convertThemeStyleConfig(config.diffContext),
    # Use diff styles as fallbacks for new fields
    diffAddedBg: convertThemeStyleConfig(config.diffAdded),
    diffRemovedBg: convertThemeStyleConfig(config.diffRemoved),
    diffAddedText: createThemeStyle("green", "default", "bright"),
    diffRemovedText: createThemeStyle("red", "default", "bright"),
    success: createThemeStyle("green", "default", "bright"),
    error: createThemeStyle("red", "default", "bright"),
    toolCall: createThemeStyle("blue", "default", "bright")
  )

proc loadThemesFromConfig*(config: configTypes.Config) =
  ## Load themes from config and set current theme
  # Always initialize built-in themes first
  initializeThemes()
  
  # Load custom themes from config if present
  if config.themes.isSome():
    for themeName, themeConfig in config.themes.get():
      registerTheme(convertThemeConfig(themeConfig))
  
  # Set current theme from config
  if config.currentTheme.isSome():
    discard setCurrentTheme(config.currentTheme.get())

proc isMarkdownEnabled*(config: configTypes.Config): bool =
  ## Check if markdown rendering is enabled in config
  if config.markdownEnabled.isSome():
    return config.markdownEnabled.get()
  return true  # Default to enabled