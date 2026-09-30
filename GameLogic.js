.pragma library

// Pure game state/rules for classic Snake — no QML/rendering dependencies,
// so it can be read and changed (or unit tested under plain JS) without
// touching Panel.qml. Panel.qml owns the render loop; this module owns
// what "one tick" means.

var UP = { dx: 0, dy: -1 }
var DOWN = { dx: 0, dy: 1 }
var LEFT = { dx: -1, dy: 0 }
var RIGHT = { dx: 1, dy: 0 }

function isOpposite(a, b) {
  return a.dx === -b.dx && a.dy === -b.dy
}

// Maps the dx/dy pairs PanelKeyCatcher's moveRequested already emits for
// arrow keys and hjkl (and the wasd equivalents Panel.qml derives the same
// way) onto the direction constants above.
function directionFromDelta(dx, dy) {
  if (dx === 1) return RIGHT
  if (dx === -1) return LEFT
  if (dy === 1) return DOWN
  if (dy === -1) return UP
  return null
}

// Creates a fresh game. `cols`/`rows` are fixed for the lifetime of the
// instance (the grid never resizes); `start()` (re)seeds a run within it.
function createGame(cols, rows) {
  return {
    cols: cols,
    rows: rows,
    mode: "wrap",
    snake: [],
    direction: RIGHT,
    pendingDirection: null,
    food: null,
    score: 0,
    started: false,
    alive: true,
    won: false,

    // Begins (or restarts) a run. `mode` is "wrap" or "solid"; omit to
    // keep whatever mode was already set.
    start: function(mode) {
      if (mode) this.mode = mode
      var startRow = Math.floor(this.rows / 2)
      var startCol = Math.floor(this.cols / 2)
      this.snake = [
        { r: startRow, c: startCol },
        { r: startRow, c: startCol - 1 },
        { r: startRow, c: startCol - 2 }
      ]
      this.direction = RIGHT
      this.pendingDirection = null
      this.score = 0
      this.alive = true
      this.won = false
      this.started = true
      this.food = this.pickFoodCell()
    },

    // Buffers the next direction. Rejects a reversal into the snake's own
    // neck by checking against the *current applied* direction, not
    // against whatever is already buffered — so two quick presses in one
    // tick (e.g. DOWN then LEFT while moving RIGHT) still can't kill the
    // snake: LEFT is compared against RIGHT (still the applied direction)
    // and correctly rejected, even though DOWN was just buffered.
    setDirection: function(dir) {
      if (!dir || isOpposite(dir, this.direction)) return
      this.pendingDirection = dir
    },

    occupiesCell: function(r, c) {
      for (var i = 0; i < this.snake.length; i++) {
        if (this.snake[i].r === r && this.snake[i].c === c) return true
      }
      return false
    },

    // Never on the snake. Returns null once the snake fills the board —
    // that state is the win condition, checked in tick() right after a
    // growth that could have caused it.
    pickFoodCell: function() {
      var free = []
      for (var r = 0; r < this.rows; r++) {
        for (var c = 0; c < this.cols; c++) {
          if (!this.occupiesCell(r, c)) free.push({ r: r, c: c })
        }
      }
      if (free.length === 0) return null
      return free[Math.floor(Math.random() * free.length)]
    },

    // Advances one step. No-op once dead, won, or before the first start().
    tick: function() {
      if (!this.alive || !this.started || this.won) return

      if (this.pendingDirection) this.direction = this.pendingDirection
      this.pendingDirection = null

      var head = this.snake[0]
      var nextR = head.r + this.direction.dy
      var nextC = head.c + this.direction.dx

      if (this.mode === "wrap") {
        nextR = (nextR + this.rows) % this.rows
        nextC = (nextC + this.cols) % this.cols
      } else if (nextR < 0 || nextR >= this.rows || nextC < 0 || nextC >= this.cols) {
        this.alive = false
        return
      }

      var willEat = !!this.food && nextR === this.food.r && nextC === this.food.c
      // The tail cell vacates this tick unless the snake is growing, so it
      // doesn't count as an obstacle for the incoming head.
      var bodyToCheck = willEat ? this.snake : this.snake.slice(0, this.snake.length - 1)
      for (var i = 0; i < bodyToCheck.length; i++) {
        if (bodyToCheck[i].r === nextR && bodyToCheck[i].c === nextC) {
          this.alive = false
          return
        }
      }

      this.snake.unshift({ r: nextR, c: nextC })
      if (willEat) {
        this.score += 10
        // Win: the snake now covers every cell, so there is nowhere left
        // to put food. Classic Snake's win condition.
        if (this.snake.length >= this.cols * this.rows) {
          this.won = true
          this.food = null
          return
        }
        this.food = this.pickFoodCell()
      } else {
        this.snake.pop()
      }
    }
  }
}
