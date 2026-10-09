import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Community theme catalog. All the work is done by ~/.local/bin/theme-picker:
// this only draws its catalog as tiles and runs its subcommands.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string cli: Quickshell.env("HOME") + "/.local/bin/theme-picker"

  // Russian for ru locales, English for everything else.
  readonly property bool russian: {
    var lang = Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || Qt.locale().name
    return String(lang).toLowerCase().indexOf("ru") === 0
  }

  function tr(ru, en) {
    return root.russian ? ru : en
  }

  property bool opened: false
  property bool loading: false
  property string loadError: ""
  property var themes: []           // everything the catalog returned
  property var shown: []            // what is left of it after the filter
  // Per-theme state lives in maps keyed by theme id, apart from the model, so
  // that an install or a finished preview repaints tiles without rebuilding
  // the grid and losing the scroll position.
  property var statusById: ({})     // "installed" | "stock" | "taken"
  property var colorsById: ({})
  property var thumbsById: ({})
  property var pickedById: ({})     // queued for install
  property var busyById: ({})       // being cloned or removed
  property var failedById: ({})     // message of the last failed install
  property string currentId: ""     // the theme the desktop uses now
  property int cursor: 0
  property string filterText: ""
  property bool installedOnly: false
  property bool working: false
  property string confirmId: ""     // theme waiting for the removal to be confirmed
  property string notice: ""
  property int installTotal: 0
  property int installDone: 0
  property int installFailed: 0

  readonly property var cursorTheme: root.cursor >= 0 && root.cursor < root.shown.length ? root.shown[root.cursor] : null
  readonly property int pickedCount: Object.keys(root.pickedById).length
  readonly property int installedCount: {
    var count = 0
    for (var id in root.statusById) {
      if (root.present(root.statusById[id])) count++
    }
    return count
  }

  property string fontFamily: Style.font.menuFamily
  // The menu background may be see-through; a grid of screenshots over a busy
  // desktop needs a nearly solid one to stay readable.
  property color background: Util.alpha(Color.menu.background, Math.max(0.95, Color.menu.background.a))
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color accent: Color.menu.selectedText
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int tileGap: Style.space(12)
  property int tileBorder: Math.max(2, Style.space(2))
  property int swatchHeight: Style.space(12)
  property int titleHeight: Style.space(30)

  function withEntry(map, key, value) {
    var next = Object.assign({}, map)
    if (value === undefined) delete next[key]
    else next[key] = value
    return next
  }

  // Stock themes count as installed everywhere except removal: they belong to
  // the omarchy package.
  function present(status) {
    return status === "installed" || status === "stock"
  }

  function statusOf(theme) {
    return theme ? (root.statusById[theme.id] || "") : ""
  }

  function installable(theme) {
    return !!theme && !!theme.url && root.statusOf(theme) === "" && root.busyById[theme.id] !== true
  }

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.installedOnly = false
    root.confirmId = ""
    root.notice = ""
    root.cursor = 0
    root.loadCatalog(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "gnome627.theme-picker")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ------------------------------------------------------------ catalog

  function loadCatalog(refresh) {
    if (catalogProc.running) return
    root.loading = true
    catalogProc.command = refresh ? [root.cli, "catalog", "--refresh"] : [root.cli, "catalog"]
    catalogProc.running = true
  }

  function applyCatalog(raw) {
    root.loading = false
    var data = null
    try { data = JSON.parse(raw) } catch (e) { data = null }
    if (!data || !Array.isArray(data.themes)) {
      root.loadError = root.tr("не удалось прочитать каталог", "could not read the catalog")
      return
    }

    var statuses = ({})
    var colors = ({})
    var thumbs = ({})
    var current = ""
    for (var i = 0; i < data.themes.length; i++) {
      var theme = data.themes[i]
      if (theme.status) statuses[theme.id] = theme.status
      if (theme.colors && theme.colors.length > 0) colors[theme.id] = theme.colors
      if (theme.thumb) thumbs[theme.id] = theme.thumb
      if (theme.current) current = theme.id
    }

    // A pick survives a reload only while the theme can still be installed.
    var picked = ({})
    for (var id in root.pickedById) {
      if (!statuses[id]) picked[id] = true
    }

    root.statusById = statuses
    root.colorsById = colors
    root.thumbsById = thumbs
    root.pickedById = picked
    root.currentId = current
    root.loadError = String(data.error || "")
    root.themes = data.themes
    root.refilter()

    if (data.pending > 0 && !syncProc.running) syncProc.running = true
  }

  function applySync(line) {
    var data = null
    try { data = JSON.parse(line) } catch (e) { return }
    if (!data || data.done) return
    if (data.colors && Object.keys(data.colors).length > 0)
      root.colorsById = Object.assign({}, root.colorsById, data.colors)
    if (data.thumbs && Object.keys(data.thumbs).length > 0)
      root.thumbsById = Object.assign({}, root.thumbsById, data.thumbs)
  }

  function matches(theme) {
    if (root.installedOnly && !root.present(root.statusOf(theme))) return false
    var needle = root.filterText.toLowerCase()
    if (!needle) return true
    return String(theme.name).toLowerCase().indexOf(needle) !== -1
        || String(theme.slug).toLowerCase().indexOf(needle) !== -1
  }

  // Rebuild the visible list, keeping the cursor on the theme it was on.
  function refilter() {
    var keep = root.cursorTheme ? root.cursorTheme.id : ""
    var next = []
    var index = -1
    for (var i = 0; i < root.themes.length; i++) {
      if (!root.matches(root.themes[i])) continue
      if (root.themes[i].id === keep) index = next.length
      next.push(root.themes[i])
    }
    root.shown = next
    root.cursor = index >= 0 ? index : Math.max(0, Math.min(root.cursor, next.length - 1))
    Qt.callLater(function() { grid.positionViewAtIndex(root.cursor, GridView.Contain) })
  }

  function setFilter(text) {
    root.filterText = text
    root.confirmId = ""
    root.refilter()
  }

  // ------------------------------------------------------------ cursor and picks

  function setCursor(index) {
    if (root.shown.length === 0) return
    root.cursor = Math.max(0, Math.min(root.shown.length - 1, index))
    root.confirmId = ""
    grid.positionViewAtIndex(root.cursor, GridView.Contain)
  }

  function togglePick(index) {
    var theme = root.shown[index]
    if (!theme || root.working) return
    root.notice = ""
    if (root.pickedById[theme.id] === true) {
      root.pickedById = root.withEntry(root.pickedById, theme.id, undefined)
    } else if (root.installable(theme)) {
      root.pickedById = root.withEntry(root.pickedById, theme.id, true)
      root.failedById = root.withEntry(root.failedById, theme.id, undefined)
    }
  }

  // ------------------------------------------------------------ install

  // Installs everything picked; with nothing picked, the highlighted theme.
  function installPicked() {
    if (root.working) return
    var urls = []
    var busy = Object.assign({}, root.busyById)
    for (var i = 0; i < root.themes.length; i++) {
      var theme = root.themes[i]
      if (root.pickedById[theme.id] === true && root.installable(theme)) {
        urls.push(theme.url)
        busy[theme.id] = true
      }
    }
    if (urls.length === 0 && root.pickedCount === 0 && root.installable(root.cursorTheme)) {
      urls.push(root.cursorTheme.url)
      busy[root.cursorTheme.id] = true
    }
    if (urls.length === 0) return

    root.busyById = busy
    root.working = true
    root.confirmId = ""
    root.notice = ""
    root.installTotal = urls.length
    root.installDone = 0
    root.installFailed = 0
    installProc.command = [root.cli, "install"].concat(urls)
    installProc.running = true
  }

  function applyInstallEvent(line) {
    var event = null
    try { event = JSON.parse(line) } catch (e) { return }
    if (!event || !event.id) return

    if (event.event === "ok") {
      root.installDone += 1
      root.statusById = root.withEntry(root.statusById, event.id, "installed")
      root.pickedById = root.withEntry(root.pickedById, event.id, undefined)
      root.busyById = root.withEntry(root.busyById, event.id, undefined)
    } else if (event.event === "fail") {
      root.installDone += 1
      root.installFailed += 1
      root.failedById = root.withEntry(root.failedById, event.id, String(event.message || ""))
      root.pickedById = root.withEntry(root.pickedById, event.id, undefined)
      root.busyById = root.withEntry(root.busyById, event.id, undefined)
    }
  }

  function finishInstall() {
    root.working = false
    root.busyById = ({})
    var installed = root.installDone - root.installFailed
    root.notice = root.installFailed > 0
      ? root.tr("Установлено: " + installed + ", с ошибкой: " + root.installFailed,
                "Installed: " + installed + ", failed: " + root.installFailed)
      : root.tr("Установлено: " + installed, "Installed: " + installed)
    if (root.installedOnly) root.refilter()
  }

  // ------------------------------------------------------------ remove

  // First call asks, the second one (Enter, or the button again) removes.
  function askRemove() {
    var theme = root.cursorTheme
    if (root.working || !theme || root.statusOf(theme) !== "installed") return
    root.notice = ""
    root.confirmId = theme.id
  }

  function confirmRemove() {
    var theme = root.cursorTheme
    if (root.working || !theme || theme.id !== root.confirmId) {
      root.confirmId = ""
      return
    }
    root.confirmId = ""
    root.working = true
    root.busyById = root.withEntry(root.busyById, theme.id, true)
    removeProc.themeId = theme.id
    removeProc.themeName = theme.name
    removeProc.local = theme.local === true
    removeProc.message = ""
    removeProc.removed = false
    removeProc.command = [root.cli, "remove", theme.slug]
    removeProc.running = true
  }

  function finishRemove() {
    var id = removeProc.themeId
    root.working = false
    root.busyById = root.withEntry(root.busyById, id, undefined)
    if (!removeProc.removed) {
      root.notice = root.tr("Не удалось удалить: ", "Could not remove: ") + (removeProc.message || removeProc.themeName)
      return
    }

    root.statusById = root.withEntry(root.statusById, id, undefined)
    if (root.currentId === id) root.currentId = ""
    root.notice = root.tr("Удалена: ", "Removed: ") + removeProc.themeName
    // A clone the catalog does not list has nothing to offer once it is gone.
    if (removeProc.local) root.themes = root.themes.filter(function(theme) { return theme.id !== id })
    if (removeProc.local || root.installedOnly) root.refilter()
  }

  Process {
    id: catalogProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCatalog(String(text || ""))
    }
  }

  Process {
    id: syncProc
    command: [root.cli, "sync"]
    stdout: SplitParser {
      onRead: function(data) { root.applySync(data) }
    }
  }

  Process {
    id: installProc
    stdout: SplitParser {
      onRead: function(data) { root.applyInstallEvent(data) }
    }
    onExited: function(exitCode, exitStatus) { root.finishInstall() }
  }

  Process {
    id: removeProc
    property string themeId: ""
    property string themeName: ""
    property bool local: false
    property bool removed: false
    property string message: ""
    stdout: SplitParser {
      onRead: function(data) {
        try {
          var event = JSON.parse(data)
          if (event.event === "ok") removeProc.removed = true
          else if (event.event === "fail") removeProc.message = String(event.message || "")
        } catch (e) {}
      }
    }
    onExited: function(exitCode, exitStatus) { root.finishRemove() }
  }

  // ------------------------------------------------------------ window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-theme-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(panel.width - Style.space(96), Style.space(1640))
      height: panel.height - Style.space(96)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var plain = event.modifiers === Qt.NoModifier || event.modifiers === Qt.KeypadModifier
          if (event.key === Qt.Key_Escape) {
            if (root.confirmId) root.confirmId = ""
            else if (root.filterText) root.setFilter("")
            else root.dismiss()
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.confirmId) root.confirmRemove()
            else root.installPicked()
          } else if (event.key === Qt.Key_Space) {
            root.togglePick(root.cursor)
          } else if (event.key === Qt.Key_Delete) {
            if (root.confirmId) root.confirmRemove()
            else root.askRemove()
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.installedOnly = !root.installedOnly
            root.confirmId = ""
            root.refilter()
          } else if (event.key === Qt.Key_F5) {
            root.loadCatalog(true)
          } else if (event.key === Qt.Key_Left) {
            root.setCursor(root.cursor - 1)
          } else if (event.key === Qt.Key_Right) {
            root.setCursor(root.cursor + 1)
          } else if (event.key === Qt.Key_Up) {
            root.setCursor(root.cursor - grid.columns)
          } else if (event.key === Qt.Key_Down) {
            root.setCursor(root.cursor + grid.columns)
          } else if (event.key === Qt.Key_PageUp) {
            root.setCursor(root.cursor - grid.columns * grid.visibleRows)
          } else if (event.key === Qt.Key_PageDown) {
            root.setCursor(root.cursor + grid.columns * grid.visibleRows)
          } else if (event.key === Qt.Key_Home && !root.filterText) {
            root.setCursor(0)
          } else if (event.key === Qt.Key_End && !root.filterText) {
            root.setCursor(root.shown.length - 1)
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) > 32 && event.text.charCodeAt(0) !== 127 && (plain || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Item {
        id: body
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ---------------------------------------------------- header
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(44)

          Text {
            id: titleText
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: root.tileGap / 2
            anchors.verticalCenter: parent.verticalCenter
            text: root.tr("Каталог тем", "Theme catalog")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.weight: Font.DemiBold
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: titleText.right
            anchors.leftMargin: Style.space(18)
            anchors.right: counters.left
            anchors.rightMargin: Style.space(18)
            anchors.baseline: titleText.baseline
            text: root.filterText
              ? root.tr("Поиск: ", "Search: ") + root.filterText + "▏"
              : root.tr("начните печатать для поиска", "type to search")
            color: root.filterText ? root.accent : root.foreground
            opacity: root.filterText ? 1 : 0.42
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: counters
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.rightMargin: root.tileGap / 2
            anchors.baseline: titleText.baseline
            text: {
              var parts = []
              if (root.installedOnly) parts.push(root.tr("только установленные", "installed only"))
              parts.push(root.tr("показано: ", "shown: ") + root.shown.length + " / " + root.themes.length)
              parts.push(root.tr("установлено: ", "installed: ") + root.installedCount)
              if (syncProc.running) parts.push(root.tr("загружаю превью…", "loading previews…"))
              return parts.join("  ·  ")
            }
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // ---------------------------------------------------- grid
        GridView {
          id: grid

          readonly property int columns: Math.max(2, Math.floor(width / Style.space(200)))
          readonly property int imageHeight: Math.round((cellWidth - root.tileGap - root.tileBorder * 2) * 9 / 16)
          readonly property int visibleRows: Math.max(1, Math.floor(height / cellHeight))

          anchors.top: header.bottom
          anchors.topMargin: Style.space(8)
          anchors.bottom: footer.top
          anchors.bottomMargin: Style.space(8)
          anchors.left: parent.left
          anchors.right: parent.right
          cellWidth: Math.floor(width / columns)
          cellHeight: imageHeight + root.swatchHeight + root.titleHeight + root.tileGap + root.tileBorder * 2
          model: root.shown
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          cacheBuffer: cellHeight * 2

          delegate: Item {
            id: cell
            required property int index
            required property var modelData

            readonly property string themeId: cell.modelData.id
            readonly property string status: root.statusById[cell.themeId] || ""
            readonly property bool hasCursor: cell.index === root.cursor
            readonly property bool picked: root.pickedById[cell.themeId] === true
            readonly property bool busy: root.busyById[cell.themeId] === true
            readonly property string failure: root.failedById[cell.themeId] || ""
            readonly property var colors: root.colorsById[cell.themeId] || []
            readonly property string thumb: root.thumbsById[cell.themeId] || ""
            readonly property string badge: {
              if (cell.busy) return cell.status === "installed" ? root.tr("удаляю…", "removing…") : root.tr("устанавливаю…", "installing…")
              if (cell.failure) return root.tr("ошибка", "failed")
              if (cell.status === "installed")
                return "✓ " + (cell.themeId === root.currentId ? root.tr("установлена · текущая", "installed · current") : root.tr("установлена", "installed"))
              if (cell.status === "stock")
                return "✓ " + (cell.themeId === root.currentId ? root.tr("встроенная · текущая", "built-in · current") : root.tr("встроенная", "built-in"))
              if (cell.status === "taken") return root.tr("имя занято", "name taken")
              return ""
            }

            width: grid.cellWidth
            height: grid.cellHeight

            Rectangle {
              id: tile
              anchors.fill: parent
              anchors.margins: root.tileGap / 2
              radius: root.cornerRadius
              color: cell.picked ? Util.alpha(root.accent, 0.2) : Util.alpha(root.foreground, cell.hasCursor ? 0.1 : 0.04)
              border.width: root.tileBorder
              border.color: cell.hasCursor ? root.accent
                : cell.picked ? Util.alpha(root.accent, 0.55)
                : Util.alpha(root.foreground, 0.12)

              Item {
                id: shot
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: root.tileBorder
                height: grid.imageHeight
                clip: true

                Rectangle {
                  anchors.fill: parent
                  color: cell.colors.length > 0 ? cell.colors[0] : Util.alpha(root.foreground, 0.06)
                }

                Image {
                  anchors.fill: parent
                  source: cell.thumb ? Util.fileUrl(cell.thumb) : ""
                  sourceSize.width: 640
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  smooth: true
                  opacity: cell.busy ? 0.45 : 1
                }

                // Pick mark, top left.
                Rectangle {
                  visible: cell.picked
                  anchors.top: parent.top
                  anchors.left: parent.left
                  anchors.margins: Style.space(6)
                  width: Style.space(24)
                  height: width
                  radius: root.cornerRadius
                  color: root.accent

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "✓"
                    color: root.background
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.weight: Font.Bold
                  }
                }

                // Status, top right.
                Rectangle {
                  visible: cell.badge !== ""
                  anchors.top: parent.top
                  anchors.right: parent.right
                  anchors.margins: Style.space(6)
                  width: badgeText.implicitWidth + Style.space(14)
                  height: badgeText.implicitHeight + Style.space(8)
                  radius: root.cornerRadius
                  color: Util.alpha(root.background, 0.88)

                  Text {
                    id: badgeText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: cell.badge
                    color: cell.failure || cell.status === "taken" ? root.urgent : root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.weight: Font.Medium
                  }
                }
              }

              Row {
                id: swatches
                anchors.top: shot.bottom
                anchors.left: shot.left
                anchors.right: shot.right
                height: root.swatchHeight

                Repeater {
                  model: cell.colors

                  delegate: Rectangle {
                    required property int index
                    required property var modelData
                    // The last swatch takes the rounding remainder.
                    readonly property int step: Math.floor(swatches.width / Math.max(1, cell.colors.length))
                    width: index === cell.colors.length - 1 ? swatches.width - step * index : step
                    height: swatches.height
                    color: modelData
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.top: swatches.bottom
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.tileBorder
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                verticalAlignment: Text.AlignVCenter
                text: cell.failure ? cell.modelData.name + " — " + cell.failure : cell.modelData.name
                color: cell.failure ? root.urgent : (cell.hasCursor || cell.picked ? root.accent : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.weight: cell.hasCursor ? Font.DemiBold : Font.Medium
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  keyCatcher.forceActiveFocus()
                  root.setCursor(cell.index)
                  root.togglePick(cell.index)
                }
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: grid
          visible: root.shown.length === 0
          text: root.loading ? root.tr("Загружаю каталог…", "Loading the catalog…")
            : root.themes.length === 0 ? root.tr("Каталог пуст", "The catalog is empty")
            : root.tr("Ничего не найдено", "No matches")
          color: root.foreground
          opacity: 0.52
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }

        // Scroll position.
        Rectangle {
          visible: grid.visibleArea.heightRatio < 1
          anchors.right: grid.right
          y: grid.y + grid.visibleArea.yPosition * grid.height
          width: Style.space(3)
          height: Math.max(Style.space(24), grid.visibleArea.heightRatio * grid.height)
          color: Util.alpha(root.foreground, 0.35)
        }

        // ---------------------------------------------------- footer
        Item {
          id: footer
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(40)

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: root.tileGap / 2
            anchors.right: buttons.left
            anchors.rightMargin: Style.space(18)
            anchors.verticalCenter: parent.verticalCenter
            readonly property bool alert: root.confirmId !== "" || (!root.working && root.notice === "" && root.loadError !== "")
            text: {
              if (root.confirmId && root.cursorTheme) {
                return root.tr("Удалить тему «", "Remove the theme “") + root.cursorTheme.name + root.tr("»?", "”?")
                  + (root.confirmId === root.currentId ? root.tr(" Она сейчас включена.", " It is the one in use.") : "")
                  + root.tr("  Enter — удалить · Esc — отмена", "  Enter — remove · Esc — cancel")
              }
              if (root.working && installProc.running)
                return root.tr("Устанавливаю: ", "Installing: ") + root.installDone + " / " + root.installTotal + "…"
              if (root.working) return root.tr("Удаляю…", "Removing…")
              if (root.notice) return root.notice
              if (root.loadError) return root.tr("Каталог не обновился: ", "The catalog did not refresh: ") + root.loadError
              return root.tr(
                "Пробел — выбрать · Enter — установить · Delete — удалить · Tab — только установленные · F5 — обновить · Esc — закрыть",
                "Space — pick · Enter — install · Delete — remove · Tab — installed only · F5 — refresh · Esc — close")
            }
            color: alert ? root.urgent : root.foreground
            opacity: alert || root.notice || root.working ? 1 : 0.52
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Row {
            id: buttons
            anchors.right: parent.right
            anchors.rightMargin: root.tileGap / 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Button {
              readonly property bool usable: !root.working && root.statusOf(root.cursorTheme) === "installed"
              text: root.confirmId ? root.tr("Точно удалить", "Really remove") : root.tr("Удалить выделенную", "Remove highlighted")
              bordered: true
              foreground: root.confirmId ? root.urgent : root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              opacity: usable ? 1 : 0.35
              onClicked: {
                keyCatcher.forceActiveFocus()
                if (!usable) return
                if (root.confirmId) root.confirmRemove()
                else root.askRemove()
              }
            }

            Button {
              readonly property int count: root.pickedCount > 0 ? root.pickedCount : (root.installable(root.cursorTheme) ? 1 : 0)
              readonly property bool usable: !root.working && count > 0
              text: root.tr("Установить", "Install") + (root.pickedCount > 0 ? " (" + root.pickedCount + ")" : "")
              bordered: true
              selected: root.pickedCount > 0
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              opacity: usable ? 1 : 0.35
              onClicked: {
                keyCatcher.forceActiveFocus()
                if (usable) root.installPicked()
              }
            }
          }
        }
      }
    }
  }
}
