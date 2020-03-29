## Lexer Module
import strformat
import strutils

from ast import Token, initToken
from source import Source
from block_string import dedentBlockStringValue
from token_kind import TokenKind

type EscapedChars = enum
  BACKSPACE = '\b'
  TABULATOR = '\t'
  LINE_FEED = '\n'
  FORM_FEED = '\f'
  CARRIAGE_RETURN = '\r'
  DOUBLE_QUOTE = '"'
  FORWARD_SLASH = '/'
  BACKSLASH = '\\'

const PunctuactionTokenKind = {TokenKind.BANG..TokenKind.BRACE_R}

proc isTokenKind(s: string): bool =
  try:
    discard parseEnum[TokenKind](s)
    return true
  except ValueError:
    return false

proc isEscapedChar(s: string): bool =
  try:
    discard parseEnum[EscapedChars](s)
    return true
  except ValueError:
    return false

proc printChar(c: char): string =
  if len(repr(c)) != 0:
    return repr(c)
  else:
    return $TokenKind.EOF

proc isNameStart(c: char): bool =
  #[
    """Check whether char is an underscore or a plain ASCII letter"""
  ]#
  return IdentStartChars.contains(c)

proc unicodeCharCode(s: string): int =
  #[
    Convert unicode string to integers.

    Converts four hexadecimal chars to the integer that the string represents.
    For example, uni_char_code('0f') will return 15,
    and uni_char_code('0','0','f','f') returns 255.

    Returns a negative number on error, if hex integer was invalid.

    This is implemented by noting that strutils fromHex proc raises
    a ValueError if `s` is not a valid hex integer. Capture the error
    and return -1 instead.
  ]#
  var intValue: int
  try:
    intValue = fromHex[int](s)
  except ValueError:
    intValue = -1
  return intValue

proc unexpectedCharacterMessage(c: char): string =
  #[
    Report a message that an unexpected character was encountered.
  ]#
  if c < ' ' and c notin "\t\n\r":
      return &"Cannot contain the invalid character {printChar(c)}."
  if c == '\'':
      return "Unexpected single quote character ('), did you mean to use a double quote (\")?"
  return &"Cannot parse the unexpected character {printChar(c)}."

proc isPunctuatorTokenKind*(kind: TokenKind): bool =
  #[
    Check whether the given token kind corresponds to a punctuator.

    For internal use only.
  ]#
  return kind in PunctuactionTokenKind

type Lexer* = object
  #[
    A Lexer is a stateful stream generator in that every time it is advanced, it returns
    the next token in the Source. Assuming the source lexes, the final Token emitted by
    the lexer will be of kind EOF, after which the lexer will repeatedly return the same
    EOF token whenever called.
  ]#
  source: Source
  lastToken: Token ## The previously focused non-ignored token.
  token: Token ## The currently focused non-ignored token.
  line: int ## The (1-indexed) line containing the current token.
  lineStart: int ## The character offset at which the current line begins.

proc initLexer*(source: Source): Lexer =
  #[
    Given a Source object, creates a Lexer for that source.
  ]#
  result.source = source
  let startOfFileToken = initToken(TokenKind.SOF, 0, 0, 0, 0)
  result.lastToken = startOfFileToken
  result.token = startOfFileToken
  result.line = 1
  result.lineStart = 0

proc positionAfterWhitespace*(self: var Lexer, body: string, startPosition: int): int =
  #[
    Go to next position after a whitespace.

    Reads from body starting at start_position until it finds a non-whitespace
    character, then returns the position of that character for lexing.
  ]#
  let bodyLen = body.len
  var pos = startPosition
  while pos < bodyLen:
    let character = body[pos]
    # Check if space, tab, comma
    if character in {' ', '\t', ','}:
      inc(pos, 1)
    elif (
      # Check if byte order mark (BOM)
      (bodyLen - pos) >= 3 and 
      body[pos] == '\xEF' and 
      body[pos + 1] == '\xBB' and 
      body[pos + 2] == '\xBF'
    ):
      inc(pos, 3)
    elif character == '\n':
      inc(pos)
      inc(self.line)
      self.lineStart = pos
    elif character == '\r':
      if body[pos + 1] == '\n':
        inc(pos, 2)
      else:
        inc(pos)
      inc(self.line)
      self.lineStart = pos
    else:
      break
  return pos

proc readComment(self: Lexer, start: int, line: int, col: int, prev: Token): Token =
  #[
    Read a comment token from the source file.
  ]#
  let body = self.source.body
  let bodyLen = body.len

  var pos = start
  while true:
    inc(pos)
    if pos >= bodyLen:
      break;
    let character = body[pos]
    if character < ' ' and character != '\t':
      break
  
  return initToken(TokenKind.COMMENT, start, pos, line, col, prev, body[start + 1..<pos])

proc readName(self: Lexer, start: int, line: int, col: int, prev: Token): Token =
  #[
    Read an alphanumeric + underscore name from the source.
  ]#
  let body = self.source.body
  let bodyLen = body.len
  var pos = start + 1
  while pos < bodyLen:
    let character = body[pos]
    if not IdentChars.contains(character):
      break
    inc(pos)
  
  return initToken(TokenKind.NAME, start, pos, line, col, prev, body[start..<pos])

proc readDigits(self: Lexer, start: int, character: var char): int =
  #[
    Return the new position in the source after reading digits.
  ]#
  let source = self.source
  let body = source.body
  let bodyLen = body.len
  var pos = start
  while Digits.contains(character):
    inc(pos)
    if pos < bodyLen - 1:
      character = body[pos]
    else:
      break
  if pos == start:
    # TODO: Should be GraphQLSyntaxError
    raise newException(ValueError, &"Invalid number, expected digit but got: {printChar(character)}.")

proc readNumber(self: Lexer, start: int, character: var char, line: int, col: int, prev: Token): Token =
  #[
    Reads a number token from the source file.
    
    Either a float or an int depending on whether a decimal point appears.
  ]#
  let source = self.source
  let body = source.body
  var pos = start
  var isFloat = false
  if character == '-':
    inc(pos)
    character = body[pos]

  if character == '0':
    inc(pos)
    character = body[pos]
    # TODO: Use Digits const from strutils
    if Digits.contains(character):
      # TODO: Should be GraphQLSyntaxError
      raise newException(ValueError, &"Invalid number, unexpected digit after 0: {printChar(character)}.")
  else:
    pos = self.readDigits(pos, character)
    character = body[pos]

  if character == '.':
    isFloat = true
    inc(pos)
    character = body[pos]
    pos = self.readDigits(pos, character)
    character = body[pos]

  if len($character) != 0 and character in "Ee":
    isFloat = true
    inc(pos)
    character = body[pos]
    if len($character) != 0 and character in "+-":
      inc(pos)
      character = body[pos]
    pos = self.readDigits(pos, character)
    character = body[pos]

  # Numbers cannot be followed by . or NameStart
  if len($character) != 0 and (character == '.' or isNameStart(character)):
    # TODO: Should be GraphQLSyntaxError
    raise newException(ValueError, &"Invalid number, expected digit but got: {printChar(character)}.")

  var finalTokenKind: TokenKind
  if isFloat:
    finalTokenKind = TokenKind.FLOAT
  else:
    finalTokenKind = TokenKind.INT
  return initToken(finalTokenKind, start, pos, line, col, prev, body[start..<pos])

proc readBlockString(self: var Lexer, start: int, line: int, col: int, prev: Token): Token =
  #[
    Reads a block string token from the source file.
  ]#
  let source = self.source
  let body = source.body
  let bodyLen = body.len
  var pos = start + 3
  var chunkStart = pos
  var rawValue = ""

  while pos < bodyLen:
    var character = body[pos]
    if character == '"' and body[pos + 1..<pos + 3] == "\"\"":
      rawValue = rawValue & body[chunkStart..<pos]
      return initToken(TokenKind.BLOCK_STRING, start, pos + 3, line, col, prev, dedentBlockStringValue(rawValue))
    if character < ' ' and character notin "\t\n\r":
      # TODO: Should be GraphQLSyntaxError
      raise newException(ValueError, &"Invalid character within String: {printChar(character)}.")
    if character == '\n':
      inc(pos)
      inc(self.line)
      self.lineStart = pos
    elif character == '\r':
      if body[pos + 1] == '\n':
        inc(pos, 2)
      else:
        inc(pos)
      inc(self.line)
      self.lineStart = pos
    elif character == '\\' and body[pos + 1..<pos + 4] == "\"\"\"":
      rawValue = rawValue & body[chunkStart..<pos] & "\"\"\""
      inc(pos, 4)
      chunkStart = pos
    else:
      inc(pos)
  
  # TODO: Should be GraphQLSyntaxError
  raise newException(ValueError, "Unterminated string.")

proc readString(self: Lexer, start: int, line: int, col: int, prev: Token): Token =
  #[
    Read a string token from the source file.
  ]#
  let source = self.source
  let body = source.body
  let bodyLen = body.len
  var pos = start + 1
  var chunkStart = pos
  var value: seq[string]

  while pos < bodyLen:
    var character = body[pos]
    if character in "\n\r":
      break
    if character == '"':
      value.add(body[chunkStart..<pos])
      return initToken(TokenKind.STRING, start, pos + 1, line, col, prev, join(value))
    if character < ' ' and character != '\t':
      # TODO: Should be GraphQLSyntaxError
      raise newException(ValueError, &"Invalid character within String: {printChar(character)}.")

    inc(pos)
    if character == '\\':
      value.add(body[chunkStart..<pos - 1])
      character = body[pos]
      let isEscaped = isEscapedChar($character)
      if isEscaped:
        value.add($character)
      elif character == 'u' and pos + 4 < bodyLen:
        let code = unicodeCharCode(body[pos + 1..<pos + 5])
        if code < 0:
          var escape = repr(body[pos..<pos + 5])
          escape = escape[0] & "\\" & escape[1..^1]
          # TODO: Should be GraphQLSyntaxError
          raise newException(ValueError, &"Invalid character escape sequence: {escape}.")
        value.add(toHex[int](code))
        inc(pos, 4)
      else:
        var escape = repr(character)
        escape = escape[0] & "\\" & escape[1..^1]
        # TODO: Should be GraphQLSyntaxError
        raise newException(ValueError, &"Invalid character escape sequence: {escape}.")
      inc(pos)
      chunkStart = pos
  # TODO: Should be GraphQLSyntaxError
  raise newException(ValueError, "Unterminated string.")

proc readToken*(self: var Lexer, prev: Token): Token =
  #[
    Get the next token from the source starting at the given position.

    This skips over whitespace until it finds the next lexable token, then lexes
    punctuators immediately or calls the appropriate helper function for more
    complicated tokens.
  ]#
  let source = self.source
  let body = source.body
  let bodyLen = body.len

  # TODO: Check pos value
  let pos = self.positionAfterWhitespace(body, prev.`end`)
  let line = self.line
  # TODO: Check col value
  let col = 1 + pos - self.lineStart

  if pos >= bodyLen:
    return initToken(TokenKind.EOF, bodyLen, bodyLen, line, col, prev)

  var character = body[pos]
  let isToken = isTokenKind($character)
  var kind: bool = false
  if isToken:
    kind = isPunctuatorTokenKind(parseEnum[TokenKind]($character))

  if kind:
    let parsedTokenKind = parseEnum[TokenKind]($character)
    return initToken(parsedTokenKind, pos, pos + 1, line, col, prev)
  elif character == '#':
    return self.readComment(pos, line, col, prev)
  elif character == '.':
    if body[pos + 1..<pos + 3] == "..":
      return initToken(TokenKind.SPREAD, pos, pos + 3, line, col, prev)
  elif IdentStartChars.contains(character):
    return self.readName(pos, line, col, prev)
  elif Digits.contains(character) or character == '-':
    return self.readNumber(pos, character, line, col, prev)
  elif character == '"':
    # Extra check as slicing outside the bounds of a sequence 
    # (for Python built-ins) does not cause an error.
    if pos + 2 < bodyLen and body[pos + 1..<pos + 3] == "\"\"":
      return self.readBlockString(pos, line, col, prev)
    return self.readString(pos, line, col, prev)
  # TODO: Should be GraphQLSyntaxError
  raise newException(ValueError, unexpectedCharacterMessage(character))

proc lookahead*(self: var Lexer): Token =
  #[
    Look ahead and return the next non-ignored token, 
    but do not change state.
  ]#
  var token = self.token
  if token.kind != TokenKind.EOF:
    while true:
      if isNil token.next:
        token.next = self.readToken(token)
      token = token.next
      if token.kind != TokenKind.COMMENT:
        break
  return token

proc advance*(self: var Lexer): Token =
  #[
    Advance the token stream to the next non-ignored token.
  ]#
  self.lastToken = self.token
  self.token = self.lookahead()
  return self.token
