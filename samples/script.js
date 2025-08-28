// Get canvas and context
const canvas = document.getElementById('pongCanvas');
const ctx = canvas.getContext('2d');

// Game objects
const ball = {
    x: canvas.width / 2,
    y: canvas.height / 2,
    radius: 10,
    velocityX: 5,
    velocityY: 5,
    speed: 5
};

const paddle1 = {
    x: 10,
    y: canvas.height / 2 - 50,
    width: 10,
    height: 100,
    score: 0,
    speed: 8
};

const paddle2 = {
    x: canvas.width - 20,
    y: canvas.height / 2 - 50,
    width: 10,
    height: 100,
    score: 0,
    speed: 8
};

// Game state
let gameRunning = false;

// Key state tracking
const keys = {};

// Event listeners for key presses
document.addEventListener('keydown', (e) => {
    keys[e.key] = true;
});

document.addEventListener('keyup', (e) => {
    keys[e.key] = false;
});

// Draw a rounded rectangle
function drawRect(x, y, width, height, radius = 0) {
    ctx.beginPath();
    ctx.moveTo(x + radius, y);
    ctx.lineTo(x + width - radius, y);
    ctx.quadraticCurveTo(x + width, y, x + width, y + radius);
    ctx.lineTo(x + width, y + height - radius);
    ctx.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
    ctx.lineTo(x + radius, y + height);
    ctx.quadraticCurveTo(x, y + height, x, y + height - radius);
    ctx.lineTo(x, y + radius);
    ctx.quadraticCurveTo(x, y, x + radius, y);
    ctx.closePath();
    ctx.fill();
}

// Draw the ball
function drawBall() {
    ctx.fillStyle = '#fff';
    ctx.beginPath();
    ctx.arc(ball.x, ball.y, ball.radius, 0, Math.PI * 2);
    ctx.fill();
}

// Draw paddles
function drawPaddle(x, y, width, height) {
    ctx.fillStyle = '#fff';
    drawRect(x, y, width, height, 5);
}

// Draw the net
function drawNet() {
    for (let i = 0; i < canvas.height; i += 20) {
        drawRect(canvas.width / 2 - 1, i, 2, 10);
    }
}

// Draw scores
function drawScores() {
    ctx.font = '48px Arial';
    ctx.textAlign = 'center';
    ctx.fillStyle = '#fff';
    ctx.fillText(paddle1.score, canvas.width / 4, 50);
    ctx.fillText(paddle2.score, 3 * canvas.width / 4, 50);
}

// Move paddles based on key presses
function movePaddles() {
    // Player 1 (W/S keys)
    if (keys['w'] || keys['W']) {
        paddle1.y = Math.max(0, paddle1.y - paddle1.speed);
    }
    if (keys['s'] || keys['S']) {
        paddle1.y = Math.min(canvas.height - paddle1.height, paddle1.y + paddle1.speed);
    }

    // Player 2 (Up/Down arrows)
    if (keys['ArrowUp']) {
        paddle2.y = Math.max(0, paddle2.y - paddle2.speed);
    }
    if (keys['ArrowDown']) {
        paddle2.y = Math.min(canvas.height - paddle2.height, paddle2.y + paddle2.speed);
    }
}

// Move the ball
function moveBall() {
    ball.x += ball.velocityX;
    ball.y += ball.velocityY;
}

// Check for collisions with walls
function checkWallCollision() {
    // Top and bottom walls
    if (ball.y + ball.radius > canvas.height || ball.y - ball.radius < 0) {
        ball.velocityY = -ball.velocityY;
    }

    // Right wall (player 1 scores)
    if (ball.x + ball.radius > canvas.width) {
        paddle1.score++;
        resetBall();
    }

    // Left wall (player 2 scores)
    if (ball.x - ball.radius < 0) {
        paddle2.score++;
        resetBall();
    }
}

// Check for collisions with paddles
function checkPaddleCollision() {
    // Paddle 1 (left)
    if (
        ball.x - ball.radius < paddle1.x + paddle1.width &&
        ball.y > paddle1.y &&
        ball.y < paddle1.y + paddle1.height &&
        ball.velocityX < 0
    ) {
        const hitPoint = (ball.y - (paddle1.y + paddle1.height / 2)) / (paddle1.height / 2);
        ball.velocityX = ball.speed;
        ball.velocityY = hitPoint * ball.speed;
    }

    // Paddle 2 (right)
    if (
        ball.x + ball.radius > paddle2.x &&
        ball.y > paddle2.y &&
        ball.y < paddle2.y + paddle2.height &&
        ball.velocityX > 0
    ) {
        const hitPoint = (ball.y - (paddle2.y + paddle2.height / 2)) / (paddle2.height / 2);
        ball.velocityX = -ball.speed;
        ball.velocityY = hitPoint * ball.speed;
    }
}

// Reset ball to center
function resetBall() {
    ball.x = canvas.width / 2;
    ball.y = canvas.height / 2;
    ball.velocityX = -ball.velocityX;
    ball.speed = 5;
}

// Game loop
function gameLoop() {
    // Clear canvas
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    // Draw game elements
    drawNet();
    drawScores();
    drawBall();
    drawPaddle(paddle1.x, paddle1.y, paddle1.width, paddle1.height);
    drawPaddle(paddle2.x, paddle2.y, paddle2.width, paddle2.height);

    if (gameRunning) {
        // Update game state
        movePaddles();
        moveBall();
        checkWallCollision();
        checkPaddleCollision();
    }

    // Continue game loop
    requestAnimationFrame(gameLoop);
}

// Start the game
function startGame() {
    gameRunning = true;
}

// Pause the game
function pauseGame() {
    gameRunning = false;
}

// Reset scores and game
function resetGame() {
    paddle1.score = 0;
    paddle2.score = 0;
    resetBall();
}

// Initialize game
gameLoop();

// Button event listeners
document.getElementById('startBtn').addEventListener('click', startGame);
document.getElementById('pauseBtn').addEventListener('click', pauseGame);
document.getElementById('resetBtn').addEventListener('click', resetGame);