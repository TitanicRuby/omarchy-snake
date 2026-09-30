import QtQuick
import qs.Commons
import qs.Ui
import "GameLogic.js" as GameLogic

// The Snake game panel. Chrome is the native popup card — the same single
// BorderSurface every built-in panel (weather, clock, power) gets from
// KeyboardPanel — with no second hand-rolled frame inside it. Only the
// pixel grid itself keeps the Nokia LCD look (rounded ghost/lit cells in
// theme background/foreground). Game state/rules live in GameLogic.js;
// this file only reads that state and draws it.
Panel {
  id: root
  moduleName: "io.github.titanicruby.snake"
  ipcTarget: "io.github.titanicruby.snake"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Closing mid-run pauses rather than leaving the game silently frozen
  // mid-tick — reopening then shows the PAUSED screen rather than jumping
  // straight back into "playing" with a stale frame. Only while actually
  // playing: game.alive stays true after a win too, so screenState (not
  // game.alive alone) is what tells "still going" apart from "over".
  // Closing from game-over/win is a deliberate "exit" choice (shown on
  // those screens as ESC EXIT, alongside SPACE RESTART/PLAY AGAIN): it
  // resets back to the unstarted state so the next open shows the real
  // start screen (mode selector + full instructions) again, instead of
  // silently resuming the stale game-over/win screen. game.started never
  // flips back to false anywhere else — see screenState above — so this
  // is the only place that has to do it.
  function close() {
    if (root.screenState === "playing") {
      root.paused = true
    } else if (root.screenState === "gameover" || root.screenState === "won") {
      root.game.started = false
      root.tickCounter++
    }
    root.controller.hide()
  }

  // Matches weather/clock's own guarded fallback for content rendered
  // before the bar has injected `bar` on first load.
  readonly property color chromeForeground: root.bar ? root.bar.foreground : Color.foreground
  readonly property string chromeFontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---- Persistence. Same mechanism the built-in clock plugin uses for
  //      its own settings (birthYear/lifeExpectancy): values live inline
  //      on this plugin's own shell.json entry, read via the inherited
  //      setting() and written back via persistSettings() below. Number(...)
  //      || 0 and the "solid"-or-"wrap" check guard against a missing or
  //      corrupted file rather than crashing on it.
  property int bestScoreWrapValue: Number(setting("bestScoreWrap", 0)) || 0
  property int bestScoreSolidValue: Number(setting("bestScoreSolid", 0)) || 0
  property string currentMode: setting("lastMode", "wrap") === "solid" ? "solid" : "wrap"

  // Merges into this plugin's own shell.json entry and pushes the change
  // up through the bar widget, matching clock's persistSettings pattern.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleMode() {
    root.currentMode = root.currentMode === "wrap" ? "solid" : "wrap"
    root.persistSettings({ lastMode: root.currentMode })
  }

  readonly property int activeBestScoreValue: currentMode === "solid" ? bestScoreSolidValue : bestScoreWrapValue

  // ---- Game state. `game` is a plain JS object (GameLogic.js), so its
  //      internal mutations aren't QML-reactive on their own; `tickCounter`
  //      is bumped on every change and read inside every binding below
  //      that needs to refresh, purely to create that dependency.
  property var game: GameLogic.createGame(gridCols, gridRows)
  property bool paused: false
  property int tickCounter: 0
  property bool lastRunWasNewBest: false

  readonly property string screenState: {
    tickCounter
    if (!game.started) return "start"
    if (game.won) return "won"
    if (!game.alive) return "gameover"
    if (root.paused) return "paused"
    return "playing"
  }
  readonly property int currentScore: { tickCounter; return game.started ? game.score : 0 }
  readonly property int bestScore: { tickCounter; return Math.max(activeBestScoreValue, currentScore) }
  readonly property bool isNewBest: lastRunWasNewBest
  readonly property bool canSelectMode: screenState === "start" || screenState === "gameover" || screenState === "won"

  // Both the game-over pixel drain and the win-screen pixel wave stagger
  // per cell; these two constants size that stagger so the whole grid's
  // worth of delays fits in a readable animation instead of a multi-second
  // crawl. winWaveLoopMs pads out to a full second sweep-and-rest cycle so
  // the diagonal wave visibly resets rather than looking arrhythmic.
  readonly property int deathDrainStepMs: 25
  // tickCounter dependency: game.snake.length is a plain JS array read,
  // not a tracked QML property — without this, the binding evaluates once
  // (while the snake array is still empty, before the first start()) and
  // never updates again, silently stuck at "+200" with no real drain delay.
  readonly property int deathDrainTotalMs: { tickCounter; return game.started ? game.snake.length * deathDrainStepMs + 200 : 0 }
  readonly property int winWaveStepMs: 20
  readonly property int winWaveMaxDelay: (gridCols - 1 + gridRows - 1) * winWaveStepMs
  readonly property int winWaveFlashMs: 360
  readonly property int winWaveLoopMs: winWaveMaxDelay + winWaveFlashMs + 300

  // Frozen at the moment of death (game.snake stops mutating once
  // !alive), so this reliably orders the drain from head (index 0) to
  // tail regardless of when it's read during the animation.
  function snakeIndexAt(rowIdx, colIdx) {
    var snake = root.game.snake
    for (var i = 0; i < snake.length; i++) {
      if (snake[i].r === rowIdx && snake[i].c === colIdx) return i
    }
    return -1
  }

  // Regression guard for the "dim leftover cells after restart" bug:
  // every ghost cell (not the fresh snake, not food) must render at full
  // opacity right after a new game starts. Runs automatically after every
  // start() via Qt.callLater below (deferred so cell delegates have
  // re-evaluated their bindings first); only ever warns, never throws, so
  // it can't itself break the game if something about the grid geometry
  // changes later.
  function debugAssertFreshBoard() {
    if (!game.started) return
    var stale = []
    for (var i = 0; i < gridCols * gridRows; i++) {
      var item = cellRepeater.itemAt(i)
      if (!item || item.kind !== "ghost") continue
      if (Math.abs(item.opacity - 1.0) > 0.001)
        stale.push("row " + item.rowIdx + " col " + item.colIdx + " opacity=" + item.opacity.toFixed(3))
    }
    if (stale.length > 0)
      console.warn("[snake] debugAssertFreshBoard: " + stale.length + " stale ghost cell(s) after newGame(): " + stale.join(", "))
  }

  Timer {
    id: gameTimer
    interval: 120
    repeat: true
    // Derived from screenState (not game.started/alive directly): game is
    // a plain JS object, so mutating its fields emits no QML change
    // signal on its own — screenState already carries the tickCounter
    // dependency that makes it react correctly.
    running: root.opened && root.screenState === "playing"
    onTriggered: {
      var wasPlaying = root.game.alive && !root.game.won
      root.game.tick()
      root.tickCounter++
      // A run "just ended" either by dying or by winning (filling the
      // board) — both check the same per-mode best.
      if (wasPlaying && (!root.game.alive || root.game.won)) {
        var isSolid = root.game.mode === "solid"
        var priorBest = isSolid ? root.bestScoreSolidValue : root.bestScoreWrapValue
        root.lastRunWasNewBest = root.game.score > priorBest
        if (root.lastRunWasNewBest) {
          if (isSolid) root.bestScoreSolidValue = root.game.score
          else root.bestScoreWrapValue = root.game.score
          root.persistSettings({ bestScoreWrap: root.bestScoreWrapValue, bestScoreSolid: root.bestScoreSolidValue })
        }
      }
    }
  }

  // ---- Grid geometry & LCD colors. Columns/rows are picked first and the
  //      panel size is derived from them — the grid is never stretched to
  //      fill leftover space. `cellSize` is one constant used for both
  //      axes, so every cell is square by construction. Two shades only
  //      (background + foreground) from the active theme's palette
  //      singleton, so the screen restyles itself on every theme change
  //      with no hardcoded colors. `lcdGhost` is the faint inactive-pixel
  //      shade; bumped enough to stay visible on both light and dark themes.
  readonly property int gridCols: 20
  readonly property int gridRows: 14
  readonly property int cellSize: Style.space(9)
  readonly property int cellGap: Style.space(2)
  readonly property color lcdBackground: Color.background
  readonly property color lcdForeground: Color.foreground
  readonly property color lcdGhost: Util.alpha(Color.foreground, 0.18)
  readonly property int gridPixelWidth: gridCols * cellSize + (gridCols - 1) * cellGap
  readonly property int gridPixelHeight: gridRows * cellSize + (gridRows - 1) * cellGap

  function cellKind(rowIdx, colIdx) {
    root.tickCounter // dependency: re-evaluate every tick
    if (!root.game.started) return "ghost"
    var snake = root.game.snake
    if (snake.length > 0 && snake[0].r === rowIdx && snake[0].c === colIdx) return "head"
    if (root.game.food && root.game.food.r === rowIdx && root.game.food.c === colIdx) return "food"
    for (var i = 1; i < snake.length; i++) {
      if (snake[i].r === rowIdx && snake[i].c === colIdx) return "body"
    }
    return "ghost"
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Sized from the content's own natural size, same as weather/clock —
    // the single popup card supplies its own uniform padding on top of
    // this, so there is never dead space and no second frame to draw.
    // `.width`/`.height`, not `.implicitWidth`/`.implicitHeight`: Column
    // reports implicit size from children's own implicit size, and plain
    // Item/Rectangle children (the header row, divider, grid) don't
    // auto-report that from their explicit `width`/`height` the way Text
    // does — implicitWidth silently undersized the card.
    //
    // fittedContentHeight adds the card's own padding/border inset for
    // you (see verticalContentInset); fittedContentWidth does not have a
    // horizontal equivalent and takes the requested width as-is. Passing
    // contentColumn.width there undersized the card by the padding *and*
    // the card border width (measured: 246 requested → 214 usable, an
    // 8px-per-side inset against a 14px padding — the extra 4px is the
    // popups border) — add both, with a little headroom, so the padded
    // content area itself is the full grid width.
    contentWidth: panel.fittedContentWidth(contentColumn.width + panel.padding * 2 + Style.space(8))
    contentHeight: panel.fittedContentHeight(contentColumn.height)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Arrow keys and hjkl arrive here already as dx/dy. Before a run
      // (start screen) and after one ends (game over), left/right instead
      // toggle the wrap/solid mode selector, so a mode picked once isn't
      // locked in for every future run in the same panel session.
      onMoveRequested: function(dx, dy) {
        if (root.canSelectMode) {
          if (dx !== 0) root.toggleMode()
          return
        }
        var dir = GameLogic.directionFromDelta(dx, dy)
        if (dir) root.game.setDirection(dir)
      }

      // wasd: PanelKeyCatcher only maps hjkl to moveRequested, so w/a/s/d
      // fall through to the generic single-character signal instead.
      // a/d mirror left/right's mode toggle.
      onTextKey: function(t) {
        var lower = t.toLowerCase()
        if (root.canSelectMode) {
          if (lower === "a" || lower === "d") root.toggleMode()
          return
        }
        var dir = lower === "w" ? GameLogic.UP
          : lower === "a" ? GameLogic.LEFT
          : lower === "s" ? GameLogic.DOWN
          : lower === "d" ? GameLogic.RIGHT
          : null
        if (dir) root.game.setDirection(dir)
      }

      // Space: starts (in the selected mode) from the start screen,
      // restarts in the same mode after game over or a win, otherwise
      // toggles pause.
      onActivateRequested: {
        if (!root.game.started || !root.game.alive || root.game.won) {
          root.game.start(root.currentMode)
          root.paused = false
          root.lastRunWasNewBest = false
          Qt.callLater(root.debugAssertFreshBoard)
        } else {
          root.paused = !root.paused
        }
        root.tickCounter++
      }

      Flickable {
        id: contentScroll
        anchors.fill: parent
        contentWidth: contentColumn.width
        contentHeight: contentColumn.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: root.gridPixelWidth
          spacing: Style.space(14)

          // ---- Header: SCORE (left) / BEST (right). Same stacked
          //      "dim uppercase label, brighter value" styling the weather
          //      panel uses for FEELS/WIND/HUMID.
          Item {
            id: headerRow
            width: root.gridPixelWidth
            height: scoreLabel.height + Style.space(5) + scoreValue.height

            Text {
              id: scoreLabel
              anchors.left: parent.left
              anchors.top: parent.top
              text: "SCORE"
              color: Qt.darker(root.chromeForeground, 1.5)
              font.family: root.chromeFontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }
            Text {
              id: scoreValue
              anchors.left: parent.left
              anchors.top: scoreLabel.bottom
              anchors.topMargin: Style.space(5)
              textFormat: Text.PlainText
              text: String(root.currentScore).padStart(4, "0")
              color: root.chromeForeground
              font.family: root.chromeFontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              id: bestLabel
              width: parent.width
              anchors.top: parent.top
              horizontalAlignment: Text.AlignRight
              text: "BEST"
              color: Qt.darker(root.chromeForeground, 1.5)
              font.family: root.chromeFontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }
            Text {
              id: bestValue
              width: parent.width
              anchors.top: bestLabel.bottom
              anchors.topMargin: Style.space(5)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: String(root.bestScore).padStart(4, "0")
              color: root.chromeForeground
              font.family: root.chromeFontFamily
              font.pixelSize: Style.font.title
            }
          }

          // ---- Divider: identical token recipe to weather's — hairline
          //      height, foreground color at low opacity.
          Rectangle {
            width: root.gridPixelWidth
            height: Style.spacing.hairline
            color: root.chromeForeground
            opacity: 0.12
          }

          // ---- Play field. A plain Item, not a Grid: cells are placed by
          //      explicit x/y (row/col * pitch) so a smaller inset food
          //      cell can sit centered in its slot without perturbing a
          //      Grid type's own automatic row/column layout.
          Item {
            id: playGrid
            width: root.gridPixelWidth
            height: root.gridPixelHeight

            Repeater {
              id: cellRepeater
              model: root.gridCols * root.gridRows

              Rectangle {
                id: cell
                required property int index
                readonly property int rowIdx: Math.floor(index / root.gridCols)
                readonly property int colIdx: index % root.gridCols
                readonly property string kind: root.cellKind(rowIdx, colIdx)
                readonly property bool isFood: kind === "food"
                // Position in the snake array at the moment of death, head
                // (0) to tail; -1 off the snake. Drives the game-over drain
                // order below. Only meaningful (and only read) once dead —
                // game.snake is frozen by then, so this stays stable for
                // the rest of the animation.
                readonly property int deathOrder: {
                  root.tickCounter
                  return root.screenState === "gameover" ? root.snakeIndexAt(rowIdx, colIdx) : -1
                }
                readonly property bool isDraining: deathOrder >= 0
                // Diagonal phase for the win-screen wave: cells further
                // from the top-left corner flash later, so the sweep
                // visibly travels across the board each loop.
                readonly property int wavePhase: rowIdx + colIdx

                // The two animations below only ever write to these scratch
                // properties, never to `opacity` directly. `opacity` itself
                // is a pure function of current state (isDraining / isFood),
                // so a cell that stops draining or stops being food snaps
                // back to fully lit as a side effect of that state changing
                // — there's no separate "restore it" step that can be missed
                // or fire at the wrong time. An animation that leaves
                // drainFade or foodFade sitting at a stale value between
                // games is harmless, because nothing reads those properties
                // once isDraining/isFood are false.
                property real drainFade: 1.0
                property real foodFade: 1.0
                opacity: isDraining ? drainFade : (isFood ? foodFade : 1.0)

                width: isFood ? Math.max(1, root.cellSize - 2) : root.cellSize
                height: width
                x: colIdx * (root.cellSize + root.cellGap) + (isFood ? 1 : 0)
                y: rowIdx * (root.cellSize + root.cellGap) + (isFood ? 1 : 0)
                radius: isFood ? Math.max(1, Math.round(root.cellSize * 0.35)) : Math.max(1, Math.round(root.cellSize * 0.2))
                antialiasing: false
                color: kind === "ghost" ? root.lcdGhost : root.lcdForeground

                // Eye punch on the head cell, echoing the bar icon's head
                // treatment so the two read as the same character. Punches
                // through to the opaque root background (not the bar's,
                // which can carry theme-defined blur transparency).
                Rectangle {
                  visible: cell.kind === "head"
                  antialiasing: false
                  width: Math.max(1, Math.round(root.cellSize * 0.3))
                  height: width
                  x: parent.width - width
                  y: 0
                  color: root.lcdBackground
                }

                // Targets the scratch `foodFade` property, not `opacity`
                // itself — see the comment above `opacity` on `cell`. Using
                // a plain NumberAnimation (rather than OpacityAnimator,
                // which can only ever target its object's real `opacity`)
                // is what makes that redirection possible.
                NumberAnimation {
                  id: foodBlink
                  target: cell
                  property: "foodFade"
                  running: cell.isFood && root.opened && root.screenState === "playing"
                  loops: Animation.Infinite
                  from: 1.0
                  to: 0.25
                  duration: 250
                  easing.type: Easing.InOutQuad
                }

                // ---- Game-over pixel drain: the dead snake evaporates
                //      head-first, one cell at a time, before the GAME
                //      OVER text fades in (see deathDrainTotalMs). A
                //      one-shot per death, not a loop. Targets `drainFade`,
                //      not `opacity` — once isDraining goes false (the next
                //      game starts), `opacity`'s own binding stops reading
                //      drainFade at all, so nothing needs to reset it back;
                //      the previous version tried to reset `opacity`
                //      imperatively from this animation's onRunningChanged,
                //      which only fires on an actual true/false transition.
                //      The drain reliably finishes (running: true -> false)
                //      within ~200ms of death, well before the player
                //      restarts, so by the time deathOrder flipped back to
                //      -1 on restart, running was already false and never
                //      changed again — the reset never ran, leaving that
                //      snake's old cells stuck dim forever. That was the
                //      root cause of the reported bug.
                SequentialAnimation {
                  running: cell.isDraining && root.opened
                  // Math.max(0, ...): duration bindings evaluate eagerly
                  // even while `running` is false, and deathOrder is -1 for
                  // the ~260+ cells not on the snake — clamped so that
                  // doesn't warn on every one of them.
                  PauseAnimation { duration: Math.max(0, cell.deathOrder * root.deathDrainStepMs) }
                  NumberAnimation { target: cell; property: "drainFade"; from: 1.0; to: 0.15; duration: 160; easing.type: Easing.OutQuad }
                }

                // ---- Win-screen pixel wave: a bright flash overlay (not
                //      the cell's own opacity — a ghost cell is already so
                //      faint that dimming it further was imperceptible)
                //      sweeps diagonally across the board, looping while
                //      the win screen is up. Every cell's sequence is
                //      padded to the same total length so the sweep
                //      re-syncs cleanly on every loop instead of drifting.
                Rectangle {
                  id: waveFlash
                  anchors.fill: parent
                  radius: parent.radius
                  antialiasing: false
                  color: root.lcdForeground
                  readonly property bool isWaving: root.screenState === "won"
                  // Same pure-binding pattern as the cell's own opacity
                  // above: the animation only ever touches the scratch
                  // `waveFade` property, and `opacity` falls back to 0 on
                  // its own the instant isWaving goes false, with no
                  // reset step that can be skipped.
                  property real waveFade: 0
                  opacity: isWaving ? waveFade : 0

                  SequentialAnimation {
                    running: waveFlash.isWaving && root.opened
                    loops: Animation.Infinite
                    PauseAnimation { duration: cell.wavePhase * root.winWaveStepMs }
                    NumberAnimation { target: waveFlash; property: "waveFade"; to: 0.9; duration: root.winWaveFlashMs / 2; easing.type: Easing.OutQuad }
                    NumberAnimation { target: waveFlash; property: "waveFade"; to: 0; duration: root.winWaveFlashMs / 2; easing.type: Easing.InQuad }
                    PauseAnimation { duration: root.winWaveLoopMs - cell.wavePhase * root.winWaveStepMs - root.winWaveFlashMs }
                  }
                }
              }
            }

            // ---- Start screen: mode selector + controls + CTA, over the
            //      ghost-only grid. Dim text here is alpha-blended toward
            //      lcdBackground (like the ghost pixels), not Qt.darker —
            //      that stays theme-symmetric (works on light and dark
            //      themes alike), where a flat darken would not.
            Column {
              anchors.centerIn: parent
              visible: root.screenState === "start"
              spacing: Style.space(10)

              Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(3)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "MODE"
                  color: Util.alpha(root.lcdForeground, 0.55)
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "◂ " + (root.currentMode === "solid" ? "SOLID" : "WRAP") + " ▸"
                  color: root.lcdForeground
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }

              Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(2)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "ARROWS / WASD   MOVE"
                  color: Util.alpha(root.lcdForeground, 0.55)
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "SPACE   START / PAUSE"
                  color: Util.alpha(root.lcdForeground, 0.55)
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "ESC   CLOSE"
                  color: Util.alpha(root.lcdForeground, 0.55)
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                text: "PRESS SPACE\nTO START"
                color: root.lcdForeground
                font.family: root.chromeFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
            }

            // ---- PAUSED overlay — scrims only the play field, not the
            //      header, so the score stays legible while paused.
            Rectangle {
              anchors.fill: parent
              visible: root.screenState === "paused"
              color: Util.alpha(root.lcdBackground, 0.8)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "PAUSED"
                color: root.lcdForeground
                font.family: root.chromeFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            // Scrim and text fade in only once the pixel drain above has
            // finished, so the snake visibly evaporates before "GAME OVER"
            // appears rather than being instantly covered by it.
            Rectangle {
              anchors.fill: parent
              visible: root.screenState === "gameover"
              color: Util.alpha(root.lcdBackground, 0.85)
              opacity: 0
              SequentialAnimation on opacity {
                running: root.screenState === "gameover"
                PauseAnimation { duration: root.deathDrainTotalMs }
                NumberAnimation { to: 1.0; duration: 250 }
              }
            }

            Column {
              anchors.centerIn: parent
              visible: root.screenState === "gameover"
              spacing: Style.space(5)
              opacity: 0
              SequentialAnimation on opacity {
                running: root.screenState === "gameover"
                PauseAnimation { duration: root.deathDrainTotalMs }
                NumberAnimation { to: 1.0; duration: 250 }
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: "GAME OVER"
                color: root.lcdForeground
                font.family: root.chromeFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: "SCORE " + String(root.currentScore).padStart(4, "0")
                color: root.lcdForeground
                font.family: root.chromeFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                visible: root.isNewBest
                text: "NEW BEST!"
                color: root.lcdForeground
                font.family: root.chromeFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.underline: true
              }

              // Mode stays changeable here too — otherwise it can only
              // ever be picked once, on the very first screen this panel
              // shows in a session.
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: "◂ " + (root.currentMode === "solid" ? "SOLID" : "WRAP") + " ▸"
                color: root.lcdForeground
                font.family: root.chromeFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                topPadding: Style.space(6)
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: "SPACE   RESTART"
                color: Util.alpha(root.lcdForeground, 0.55)
                font.family: root.chromeFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: "ESC   EXIT"
                color: Util.alpha(root.lcdForeground, 0.55)
                font.family: root.chromeFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // ---- WIN overlay: a local backing behind the text only, not
            //      a full-grid scrim — the whole board's diagonal pixel
            //      wave (on the cells above) is the celebration, and
            //      dimming all of it would undercut that.
            Item {
              anchors.centerIn: parent
              visible: root.screenState === "won"
              width: winColumn.width + Style.space(20)
              height: winColumn.height + Style.space(14)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Util.alpha(root.lcdBackground, 0.85)
              }

              Column {
                id: winColumn
                anchors.centerIn: parent
                spacing: Style.space(5)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "YOU WIN!"
                  color: root.lcdForeground
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "BOARD FULL"
                  color: Util.alpha(root.lcdForeground, 0.65)
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "SCORE " + String(root.currentScore).padStart(4, "0")
                  color: root.lcdForeground
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  visible: root.isNewBest
                  text: "NEW BEST!"
                  color: root.lcdForeground
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  font.underline: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "◂ " + (root.currentMode === "solid" ? "SOLID" : "WRAP") + " ▸"
                  color: root.lcdForeground
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  topPadding: Style.space(6)
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "SPACE   PLAY AGAIN"
                  color: Util.alpha(root.lcdForeground, 0.55)
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "ESC   EXIT"
                  color: Util.alpha(root.lcdForeground, 0.55)
                  font.family: root.chromeFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }
}
