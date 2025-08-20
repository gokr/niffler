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

# Global theme registry
var themeRegistry: Table[string, Theme]
var currentTheme: Theme

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

proc createThemeStyle*(color: string, style: string = "bright"): ThemeStyle =
  ## Create a ThemeStyle from color and style strings
  ThemeStyle(
    color: parseColor(color),
    style: parseStyle(style)
  )

proc getDefaultTheme*(): Theme =
  ## Get the default theme matching current TUI colors
  Theme(
    name: "default",
    header1: createThemeStyle("yellow", "bright"),
    header2: createThemeStyle("yellow", "bright"),
    header3: createThemeStyle("yellow", "dim"),
    bold: createThemeStyle("white", "bright"),
    italic: createThemeStyle("cyan", "bright"),
    code: createThemeStyle("green", "dim"),
    link: createThemeStyle("blue", "bright"),
    listBullet: createThemeStyle("white", "bright"),
    codeBlock: createThemeStyle("cyan", "bright"),
    normal: createThemeStyle("white", "bright")
  )

proc getDarkTheme*(): Theme =
  ## Get a theme optimized for dark terminals
  Theme(
    name: "dark",
    header1: createThemeStyle("blue", "bright"),
    header2: createThemeStyle("cyan", "bright"),
    header3: createThemeStyle("cyan", "dim"),
    bold: createThemeStyle("white", "bright"),
    italic: createThemeStyle("yellow", "bright"),
    code: createThemeStyle("green", "bright"),
    link: createThemeStyle("magenta", "bright"),
    listBullet: createThemeStyle("cyan", "bright"),
    codeBlock: createThemeStyle("blue", "dim"),
    normal: createThemeStyle("white", "bright")
  )

proc getLightTheme*(): Theme =
  ## Get a theme optimized for light terminals
  Theme(
    name: "light",
    header1: createThemeStyle("blue", "bright"),
    header2: createThemeStyle("magenta", "bright"),
    header3: createThemeStyle("magenta", "dim"),
    bold: createThemeStyle("black", "bright"),
    italic: createThemeStyle("blue", "dim"),
    code: createThemeStyle("green", "dim"),
    link: createThemeStyle("blue", "bright"),
    listBullet: createThemeStyle("black", "bright"),
    codeBlock: createThemeStyle("magenta", "dim"),
    normal: createThemeStyle("black", "bright")
  )

proc getMinimalTheme*(): Theme =
  ## Get a minimal monochrome theme
  Theme(
    name: "minimal",
    header1: createThemeStyle("white", "bright"),
    header2: createThemeStyle("white", "bright"),
    header3: createThemeStyle("white", "dim"),
    bold: createThemeStyle("white", "bright"),
    italic: createThemeStyle("white", "dim"),
    code: createThemeStyle("white", "dim"),
    link: createThemeStyle("white", "underscore"),
    listBullet: createThemeStyle("white", "bright"),
    codeBlock: createThemeStyle("white", "dim"),
    normal: createThemeStyle("white", "bright")
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

proc getCurrentTheme*(): Theme =
  ## Get the current active theme
  result = currentTheme

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
  
  let styleCode = case themeStyle.style:
    of styleBright: "\x1b[1m"
    of styleDim: "\x1b[2m"
    of styleItalic: "\x1b[3m"
    of styleUnderscore: "\x1b[4m"
    of styleBlink: "\x1b[5m"
    of styleReverse: "\x1b[7m"
    of styleStrikethrough: "\x1b[9m"
    else: "\x1b[1m"  # Default to bright
  
  result = styleCode & colorCode & text & "\x1b[0m"

proc convertThemeStyleConfig(config: configTypes.ThemeStyleConfig): ThemeStyle =
  ## Convert config ThemeStyleConfig to theme ThemeStyle
  ThemeStyle(
    color: parseColor(config.color),
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
    normal: convertThemeStyleConfig(config.normal)
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