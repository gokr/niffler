import std/[strutils, terminal]

# Game data structures
type
  Player = enum
    None, X, O
  
  Game = object
    board: array[3, array[3, Player]]
    currentPlayer: Player
    gameOver: bool
    winner: Player

# Initialize a new game
proc initGame(): Game =
  result.currentPlayer = X
  result.gameOver = false
  result.winner = None
  for i in 0..2:
    for j in 0..2:
      result.board[i][j] = None

# Display the game board
proc displayBoard(game: Game) =
  stdout.write("\n")
  for i in 0..2:
    for j in 0..2:
      case game.board[i][j]:
      of X:
        stdout.write(" X ")
      of O:
        stdout.write(" O ")
      of None:
        stdout.write("   ")
      
      if j < 2:
        stdout.write("|")
    stdout.write("\n")
    if i < 2:
      echo "---+---+---"
  stdout.write("\n")

# Check for a winner
proc checkWinner(game: var Game) =
  # Check rows
  for i in 0..2:
    if game.board[i][0] != None and 
       game.board[i][0] == game.board[i][1] and 
       game.board[i][1] == game.board[i][2]:
      game.winner = game.board[i][0]
      game.gameOver = true
      return
  
  # Check columns
  for j in 0..2:
    if game.board[0][j] != None and 
       game.board[0][j] == game.board[1][j] and 
       game.board[1][j] == game.board[2][j]:
      game.winner = game.board[0][j]
      game.gameOver = true
      return
  
  # Check diagonals
  if game.board[0][0] != None and 
     game.board[0][0] == game.board[1][1] and 
     game.board[1][1] == game.board[2][2]:
    game.winner = game.board[0][0]
    game.gameOver = true
    return
  
  if game.board[0][2] != None and 
     game.board[0][2] == game.board[1][1] and 
     game.board[1][1] == game.board[2][0]:
    game.winner = game.board[0][2]
    game.gameOver = true
    return
  
  # Check for tie
  var isFull = true
  for i in 0..2:
    for j in 0..2:
      if game.board[i][j] == None:
        isFull = false
        break
    if not isFull:
      break
  
  if isFull:
    game.gameOver = true

# Make a move
proc makeMove(game: var Game, row, col: int): bool =
  if row >= 0 and row <= 2 and col >= 0 and col <= 2 and game.board[row][col] == None:
    game.board[row][col] = game.currentPlayer
    return true
  return false

# Switch player
proc switchPlayer(game: var Game) =
  if game.currentPlayer == X:
    game.currentPlayer = O
  else:
    game.currentPlayer = X

# Get player input
proc getPlayerInput(): tuple[row, col: int] =
  while true:
    echo "Enter row and column (0-2) separated by space: "
    let input = stdin.readLine().strip()
    
    let parts = input.split()
    if parts.len != 2:
      echo "Please enter two numbers separated by space."
      continue
    
    try:
      let row = parts[0].parseInt()
      let col = parts[1].parseInt()
      
      if row >= 0 and row <= 2 and col >= 0 and col <= 2:
        return (row, col)
      else:
        echo "Row and column must be between 0 and 2."
    except ValueError:
      echo "Please enter valid numbers."

# Display game result
proc displayResult(game: Game) =
  if game.winner != None:
    echo "Player " & $game.winner & " wins!"
  else:
    echo "It's a tie!"

# Main game loop
proc playGame() =
  var game = initGame()
  
  echo "Welcome to Tic Tac Toe!"
  echo "Player X goes first."
  
  while not game.gameOver:
    displayBoard(game)
    echo "Player " & $game.currentPlayer & "'s turn"
    
    let (row, col) = getPlayerInput()
    
    if makeMove(game, row, col):
      checkWinner(game)
      if not game.gameOver:
        switchPlayer(game)
    else:
      echo "Invalid move! Try again."
  
  displayBoard(game)
  displayResult(game)

# Entry point
when isMainModule:
  playGame()