import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the Snake plugin: a small pixel-art snake that follows the
// bar's theme foreground color, plus the host for the game panel.
BarWidget {
  id: root
  moduleName: "io.github.titanicruby.snake"

  // ---- Panel forwarding. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: Math.ceil(icon.extent / 2) + 1
    verticalPadding: 4

    onPressed: function(b) {
      root.togglePanel()
    }

    // Pixel-art snake glyph: hand-placed blocks (not a dense grid) so the
    // S-shaped body, the head, and the separate food pixel each stay
    // recognizable at real bar-icon size. Every position/size below is an
    // integer multiple of `unit`/`gap`, and every Rectangle disables
    // antialiasing, so nothing sub-pixel blurs the edges.
    Item {
      id: icon
      anchors.centerIn: parent
      width: extent
      height: extent

      readonly property int block: Math.max(3, Math.floor((Style.bar.iconCanvas + 4) / 6))
      readonly property int gap: Math.max(1, Math.floor(Style.bar.iconCanvas / 16))
      readonly property int pitch: block + gap
      // 5x5 logical cells: an S-shaped body (tail to neck), a head cell
      // with an eye punch, and one food pixel in the opposite corner.
      readonly property var body: [
        { r: 4, c: 0 }, { r: 4, c: 1 }, { r: 3, c: 1 }, { r: 2, c: 1 }, { r: 2, c: 2 }
      ]
      readonly property var head: ({ r: 2, c: 3 })
      readonly property var food: ({ r: 0, c: 4 })
      readonly property int extent: 4 * pitch + block

      Repeater {
        model: icon.body

        Rectangle {
          required property var modelData
          antialiasing: false
          x: modelData.c * icon.pitch
          y: modelData.r * icon.pitch
          width: icon.block
          height: icon.block
          color: button.foreground
        }
      }

      // Head: one pixel bigger than a body block on its free (top/right)
      // sides, so it reads as the head without depending on punching a
      // background-colored hole — the bar's own background can be
      // theme-blurred/translucent, which made a hole-in-the-fill blend
      // away to invisible instead of reading as an eye.
      Rectangle {
        antialiasing: false
        x: icon.head.c * icon.pitch
        y: icon.head.r * icon.pitch - 1
        width: icon.block + 1
        height: icon.block + 1
        color: button.foreground
      }

      // Food: smaller and dimmer than a body block, so it never reads as
      // part of the snake.
      Rectangle {
        antialiasing: false
        readonly property int size: Math.max(1, icon.block - 1)
        x: icon.food.c * icon.pitch + Math.floor((icon.block - size) / 2)
        y: icon.food.r * icon.pitch + Math.floor((icon.block - size) / 2)
        width: size
        height: size
        color: Util.alpha(button.foreground, 0.65)
      }
    }
  }
}
