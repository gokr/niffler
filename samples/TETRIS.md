# Tetris Implementation Plan

## Overview
This document outlines a comprehensive plan for implementing a classic Tetris game as a single HTML page using JavaScript and CSS.

## Game Architecture

### Core Components
1. **Game Board** - 10x20 grid for piece placement
2. **Tetromino System** - 7 distinct piece shapes with rotation logic
3. **Game Loop** - Timing, piece movement, and collision detection
4. **Input Handler** - Keyboard controls for piece manipulation
5. **Scoring System** - Points, levels, and line clearing
6. **UI/State Management** - Game states (playing, paused, game over)

## Implementation Steps

### Phase 1: Basic Structure and Styling
1. **HTML Structure**
   - Game board container
   - Score and level display
   - Next piece preview
   - Game controls (start, pause, restart)
   - Game over overlay

2. **CSS Styling**
   - Grid-based layout for game board
   - Tetromino piece colors and styles
   - Responsive design considerations
   - Animations for line clearing and piece movement

### Phase 2: Game Logic Implementation
1. **Tetromino Definitions**
   - Define 7 piece shapes (I, O, T, S, Z, J, L)
   - Implement rotation matrices
   - Create piece spawning system

2. **Board Management**
   - 2D array representation of game board
   - Collision detection functions
   - Line clearing algorithm
   - Board rendering and updates

3. **Game Mechanics**
   - Piece movement (left, right, down, rotate)
   - Gravity system (automatic falling)
   - Lock delay mechanism
   - Wall and floor collision

### Phase 3: Advanced Features
1. **Scoring System**
   - Points for line clears (1 line = 100, 2 lines = 300, 3 lines = 500, 4 lines = 800)
   - Level progression (every 10 lines)
   - Speed increase with levels

2. **Game States**
   - Start screen
   - Playing state
   - Paused state
   - Game over state
   - High score tracking

3. **Controls**
   - Arrow keys for movement
   - Space for hard drop
   - Up arrow for rotation
   - P for pause
   - R for restart

### Phase 4: Polish and Optimization
1. **Visual Enhancements**
   - Smooth animations
   - Particle effects for line clears
   - Ghost piece preview
   - Sound effects (optional)

2. **Performance Optimization**
   - Efficient rendering
   - RequestAnimationFrame usage
   - Memory management
   - Mobile responsiveness

## File Structure
```
tetris.html          # Single HTML file with embedded CSS and JS
├── HTML structure
├── <style> section with all CSS
└── <script> section with all JavaScript
```

## Technical Implementation Details

### HTML Structure
```html
<div class="game-container">
  <div class="game-board" id="gameBoard"></div>
  <div class="game-info">
    <div class="score-display">
      <div>Score: <span id="score">0</span></div>
      <div>Level: <span id="level">1</span></div>
      <div>Lines: <span id="lines">0</span></div>
    </div>
    <div class="next-piece" id="nextPiece"></div>
    <div class="controls">
      <button id="startBtn">Start</button>
      <button id="pauseBtn">Pause</button>
      <button id="restartBtn">Restart</button>
    </div>
  </div>
</div>
```

### CSS Architecture
- Grid-based layout for game board
- CSS variables for easy theming
- Transforms for piece rotation
- Keyframe animations for line clearing

### JavaScript Architecture
```javascript
// Core game object
const Tetris = {
  board: [],
  currentPiece: null,
  nextPiece: null,
  score: 0,
  level: 1,
  lines: 0,
  isPlaying: false,
  isPaused: false,
  
  // Main methods
  init(),
  start(),
  pause(),
  restart(),
  gameLoop(),
  updateBoard(),
  checkLines(),
  spawnPiece(),
  movePiece(direction),
  rotatePiece(),
  dropPiece()
};

// Tetromino definitions
const TETROMINOES = {
  I: { shape: [[1,1,1,1]], color: '#00f0f0' },
  O: { shape: [[1,1],[1,1]], color: '#f0f000' },
  T: { shape: [[0,1,0],[1,1,1]], color: '#a000f0' },
  S: { shape: [[0,1,1],[1,1,0]], color: '#00f000' },
  Z: { shape: [[1,1,0],[0,1,1]], color: '#f00000' },
  J: { shape: [[1,0,0],[1,1,1]], color: '#0000f0' },
  L: { shape: [[0,0,1],[1,1,1]], color: '#f0a000' }
};
```

## Key Algorithms

### Collision Detection
```javascript
function checkCollision(piece, board, offsetX, offsetY) {
  for (let y = 0; y < piece.shape.length; y++) {
    for (let x = 0; x < piece.shape[y].length; x++) {
      if (piece.shape[y][x]) {
        const newX = piece.x + x + offsetX;
        const newY = piece.y + y + offsetY;
        
        if (newX < 0 || newX >= BOARD_WIDTH || 
            newY >= BOARD_HEIGHT || 
            (newY >= 0 && board[newY][newX])) {
          return true;
        }
      }
    }
  }
  return false;
}
```

### Line Clearing
```javascript
function clearLines() {
  let linesCleared = 0;
  
  for (let y = BOARD_HEIGHT - 1; y >= 0; y--) {
    if (board[y].every(cell => cell !== 0)) {
      board.splice(y, 1);
      board.unshift(new Array(BOARD_WIDTH).fill(0));
      linesCleared++;
      y++; // Check the same row again
    }
  }
  
  updateScore(linesCleared);
  return linesCleared;
}
```

### Piece Rotation
```javascript
function rotatePiece(piece) {
  const rotated = piece.shape[0].map((_, index) =>
    piece.shape.map(row => row[index]).reverse()
  );
  
  // Check if rotation is valid
  const tempPiece = { ...piece, shape: rotated };
  if (!checkCollision(tempPiece, board, 0, 0)) {
    piece.shape = rotated;
  }
}
```

## Constants and Configuration
```javascript
const BOARD_WIDTH = 10;
const BOARD_HEIGHT = 20;
const INITIAL_SPEED = 1000; // milliseconds
const SPEED_DECREMENT = 50; // speed increase per level
const LINES_PER_LEVEL = 10;

const SCORES = {
  1: 100,   // Single line
  2: 300,   // Double line
  3: 500,   // Triple line
  4: 800    // Tetris
};
```

## Implementation Timeline

### Day 1: Setup and Basic Structure
- [ ] Create HTML structure
- [ ] Implement CSS styling
- [ ] Set up basic JavaScript architecture
- [ ] Create board rendering system

### Day 2: Core Game Logic
- [ ] Implement tetromino system
- [ ] Add collision detection
- [ ] Create piece movement and rotation
- [ ] Implement line clearing

### Day 3: Game Mechanics
- [ ] Add scoring system
- [ ] Implement level progression
- [ ] Add game state management
- [ ] Create input handling

### Day 4: Polish and Features
- [ ] Add next piece preview
- [ ] Implement ghost piece
- [ ] Add animations and effects
- [ ] Optimize performance

### Day 5: Testing and Refinement
- [ ] Test all game mechanics
- [ ] Fix bugs and edge cases
- [ ] Optimize for mobile
- [ ] Final polish and documentation

## Testing Strategy
1. **Unit Testing**: Individual functions (collision, rotation, line clearing)
2. **Integration Testing**: Game flow and state transitions
3. **User Testing**: Playability and controls
4. **Performance Testing**: Frame rate and responsiveness
5. **Cross-browser Testing**: Compatibility across browsers

## Known Challenges and Solutions
1. **Rotation Kicks**: Implement wall/floor kicks for smooth rotation
2. **Lock Delay**: Add brief delay when piece lands
3. **Input Buffering**: Handle rapid key presses
4. **Mobile Controls**: Implement touch controls for mobile devices
5. **Performance**: Optimize rendering for smooth gameplay

## Extensions and Future Enhancements
1. **High Score System**: Local storage for persistent scores
2. **Sound Effects**: Audio feedback for actions
3. **Themes**: Multiple color schemes and visual styles
4. **Multiplayer**: Networked multiplayer functionality
5. **AI Opponent**: Computer player for practice

## Resources and References
- [Tetris Guidelines](https://tetris.fandom.com/wiki/Tetris_Guideline)
- [Modern Tetris mechanics](https://harddrop.com/wiki/Tetris_Guideline)
- [JavaScript game development best practices](https://developer.mozilla.org/en-US/docs/Games)

This plan provides a comprehensive roadmap for creating a fully functional Tetris game in a single HTML file with modern web technologies.