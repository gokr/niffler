// Game variables
const canvas = document.getElementById('pongCanvas');
const ctx = canvas.getContext('2d');
const player1ScoreElem = document.getElementById('player1Score');
const player2ScoreElem = document.getElementById('player2Score');
const startBtn = document.getElementById('startBtn');
const resetBtn = document.getElementById('resetBtn');

// Game state
let gameRunning = false;
let animationId;

// Paddle properties
const paddleWidth = 10;
const paddleHeight = 80;
const paddleSpeed = 8;

// Ball properties
const ballSize = 10;
let ballSpeedX = 5;
let ballSpeedY = 5;

// Game objects
let player1 = {
    x: 10,
    y: canvas.height / 2 - paddleHeight / 2,
    width: paddleWidth,
    height: paddleHeight,
    score: 0
};

let player2 = {
    x: canvas.width - paddleWidth - 10,
    y: canvas.height / 2 - paddleHeight / 2,
    width: paddleWidth,
    height: paddleHeight,
    score: 0
};

let ball = {
    x: canvas.width / 2,
    y: canvas.height / 2,
    width: ballSize,
    height: ballSize
};

// Key state tracking
const keys = {};

// Event listeners
document.addEventListener('keydown', (e) => {
    keys[e.key] = true;
});

document.addEventListener('keyup', (e) => {
    keys[e.key] = false;
});

startBtn.addEventListener('click', startGame);
resetBtn.addEventListener('click', resetGame);

// Game functions
function startGame() {
    if (!gameRunning) {
        gameRunning = true;
        resetBall();
        gameLoop();
    }
}

function resetGame() {
    gameRunning = false;
    cancelAnimationFrame(animationId);
    player1.score = 0;
    player2.score = 0;
    player1ScoreElem.textContent = '0';
    player2ScoreElem.textContent = '0';
    resetBall();
    draw();
}

function resetBall() {
    ball.x = canvas.width / 2;
    ball.y = canvas.height / 2;
    
    // Randomize ball direction
    ballSpeedX = (Math.random() > 0.5 ? 1 : -1) * 5;
    ballSpeedY = (Math.random() * 4) - 2; // -2 to 2
}

function gameLoop() {
    if (!gameRunning) return;
    
    update();
    draw();
    
    animationId = requestAnimationFrame(gameLoop);
}

function update() {
    // Move player 1 (W/S keys)
    if (keys['w'] || keys['W']) {
        player1.y = Math.max(0, player1.y - paddleSpeed);
    }
    if (keys['s'] || keys['S']) {
        player1.y = Math.min(canvas.height - paddleHeight, player1.y + paddleSpeed);
    }
    
    // Move player 2 (Arrow keys)
    if (keys['ArrowUp']) {
        player2.y = Math.max(0, player2.y - paddleSpeed);
    }
    if (keys['ArrowDown']) {
        player2.y = Math.min(canvas.height - paddleHeight, player2.y + paddleSpeed);
    }
    
    // Move ball
    ball.x += ballSpeedX;
    ball.y += ballSpeedY;
    
    // Wall collision (top/bottom)
    if (ball.y <= 0 || ball.y + ballSize >= canvas.height) {
        ballSpeedY = -ballSpeedY;
    }
    
    // Paddle collision
    // Player 1
    if (ball.x <= player1.x + player1.width &&
        ball.y >= player1.y &&
        ball.y <= player1.y + player1.height &&
        ballSpeedX < 0) {
        ballSpeedX = -ballSpeedX;
        let deltaY = ball.y - (player1.y + player1.height / 2);
        ballSpeedY = deltaY * 0.2;
    }
    
    // Player 2
    if (ball.x + ballSize >= player2.x &&
        ball.y >= player2.y &&
        ball.y <= player2.y + player2.height &&
        ballSpeedX > 0) {
        ballSpeedX = -ballSpeedX;
        let deltaY = ball.y - (player2.y + player2.height / 2);
        ballSpeedY = deltaY * 0.2;
    }
    
    // Score points
    if (ball.x < 0) {
        player2.score++;
        player2ScoreElem.textContent = player2.score;
        resetBall();
    }
    
    if (ball.x > canvas.width) {
        player1.score++;
        player1ScoreElem.textContent = player1.score;
        resetBall();
    }
}

function draw() {
    // Clear canvas
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    
    // Draw center line
    ctx.strokeStyle = '#fff';
    ctx.setLineDash([10, 10]);
    ctx.beginPath();
    ctx.moveTo(canvas.width / 2, 0);
    ctx.lineTo(canvas.width / 2, canvas.height);
    ctx.stroke();
    ctx.setLineDash([]);
    
    // Draw paddles
    ctx.fillStyle = '#fff';
    ctx.fillRect(player1.x, player1.y, player1.width, player1.height);
    ctx.fillRect(player2.x, player2.y, player2.width, player2.height);
    
    // Draw ball
    ctx.fillRect(ball.x, ball.y, ball.width, ball.height);
}

// Initial draw
draw();