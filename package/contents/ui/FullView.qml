import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami

// The popup is exactly as tall as what it shows. Fixed bounds also override the
// size that Plasma saves for popups.
ColumnLayout {
    id: full

    required property var app

    readonly property int popupWidth: Kirigami.Units.gridUnit * 18
    readonly property int maxDay: Math.max.apply(null, app.days.concat([1]))
    property int draggedTab: -1
    property int dropTab: -1
    readonly property string paceWarning: {
        const w = app.mainWindow
        const used = app.usedMain
        if (!w || !w.length || w.resetsAt <= app.now || used <= 0 || app.limited) return ""
        const elapsed = 1 - (w.resetsAt - app.now) / w.length
        if (elapsed < 0.15) return ""
        const emptyIn = (1 - used) * (elapsed * w.length / used)
        if (app.now + emptyIn >= w.resetsAt) return ""
        return i18n("Out of quota around %1 at this pace", new Date((app.now + emptyIn) * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat))
    }
    readonly property string infoText: {
        if (paceWarning) return paceWarning
        let text = i18n("%1 tokens today", formatTokens(app.days[6] || 0))
        if (app.current.costToday > 0)
            text += " · " + Number(app.current.costToday).toLocaleString(Qt.locale(), "f", 2) + " $"
        if (!app.hasQuota) return i18n("No known limit · %1", text)
        const w = app.mainWindow
        return w && w.resetsAt > app.now ? app.resetPhrase(w) + " · " + text : text
    }

    Layout.minimumWidth: popupWidth
    Layout.preferredWidth: popupWidth
    Layout.maximumWidth: popupWidth
    Layout.minimumHeight: implicitHeight
    Layout.preferredHeight: implicitHeight
    Layout.maximumHeight: implicitHeight
    spacing: Kirigami.Units.smallSpacing

    function formatTokens(n) {
        if (n >= 1000000) return Number(n / 1000000).toLocaleString(Qt.locale(), "f", 1) + " M"
        if (n >= 1000) return Math.round(n / 1000) + " k"
        return String(n)
    }

    function selectCurrentTab() {
        agentBar.currentIndex = app.installedAgents.indexOf(app.agent)
    }

    Connections {
        target: full.app
        function onAgentChanged() { full.selectCurrentTab() }
        function onInstalledAgentsChanged() { Qt.callLater(full.selectCurrentTab) }
    }

    // ---- What could not be opened ----
    PC3.Label {
        visible: full.app.launchError !== ""
        text: full.app.launchError
        color: Kirigami.Theme.negativeTextColor
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }

    // ---- Agent switch: a tab can be dragged to another place ----
    PC3.TabBar {
        id: agentBar
        visible: full.app.installedAgents.length > 1
        Layout.fillWidth: true
        currentIndex: full.app.installedAgents.indexOf(full.app.agent)

        Repeater {
            model: full.app.installedAgents
            PC3.TabButton {
                id: tab
                required property string modelData
                required property int index
                text: full.app.agentNames[modelData]
                opacity: full.draggedTab === index ? 0.5 : 1
                onClicked: full.app.setAgent(modelData)

                DragHandler {
                    target: null
                    yAxis.enabled: false
                    onCentroidChanged: {
                        if (!active) return
                        const x = agentBar.mapFromItem(null, centroid.scenePosition.x, centroid.scenePosition.y).x
                        const count = full.app.installedAgents.length
                        full.dropTab = Math.max(0, Math.min(count - 1, Math.floor(x / agentBar.width * count)))
                    }
                    onActiveChanged: {
                        if (active) {
                            full.draggedTab = tab.index
                            full.dropTab = tab.index
                        } else {
                            // later: moving the tab destroys this handler
                            if (full.dropTab !== full.draggedTab) Qt.callLater(full.app.moveAgent, tab.modelData, full.dropTab)
                            full.draggedTab = -1
                        }
                    }
                }
                Rectangle {  // where the tab would land
                    visible: full.draggedTab >= 0 && full.dropTab === tab.index && full.draggedTab !== tab.index
                    x: full.dropTab > full.draggedTab ? parent.width - width : 0
                    width: 2
                    height: parent.height
                    color: Kirigami.Theme.highlightColor
                }
            }
        }
    }

    // ---- Usage of the current agent ----
    RowLayout {
        visible: full.app.hasQuota
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing

        Repeater {
            model: full.app.windows
            UsageMeter {
                required property var modelData
                title: full.app.windowLabel(modelData)
                windowData: modelData
                windowLength: modelData.length || 0
                used: full.app.currentUse(modelData)
                now: full.app.now
                resetPhrase: full.app.resetPhrase(modelData)
                barColor: full.app.quotaColor(full.app.currentUse(modelData), full.app.isLimited(modelData))
                Layout.preferredWidth: 1
            }
        }
    }

    // ---- Pace warning, or reset and tokens ----
    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        PC3.Label {
            text: full.infoText
            color: full.paceWarning ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
            opacity: full.paceWarning ? 1 : 0.7
            font: Kirigami.Theme.smallFont
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        Row {  // the last 7 days
            spacing: 1
            Layout.alignment: Qt.AlignBottom
            Repeater {
                model: 7
                Item {
                    required property int index
                    width: 4
                    height: 12
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(1, Math.round(12 * (full.app.days[parent.index] || 0) / full.maxDay))
                        color: "#94e2d5"  // Catppuccin Mocha teal, like the bowl's water
                        opacity: parent.index === 6 ? 1 : 0.5
                    }
                }
            }
        }
    }

    // ---- Recent projects ----
    PC3.Label {
        visible: full.app.projects.length > 0
        text: i18n("Recent projects")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        Layout.topMargin: Kirigami.Units.smallSpacing
    }
    Repeater {
        model: full.app.projects
        RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: 0

            PC3.ItemDelegate {
                text: parent.modelData.name
                icon.name: "folder"
                Layout.fillWidth: true
                PC3.ToolTip.text: parent.modelData.path
                PC3.ToolTip.visible: hovered
                PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                onClicked: full.app.openTerminal(parent.modelData.path, "")
            }
            PC3.ToolButton {
                icon.name: "view-history"
                display: PC3.AbstractButton.IconOnly
                text: i18n("Resume the last session")
                PC3.ToolTip.text: text
                PC3.ToolTip.visible: hovered
                PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                onClicked: full.app.openTerminal(parent.modelData.path, parent.modelData.session)
            }
        }
    }

    // ---- Tools ----
    RowLayout {
        Layout.fillWidth: true
        spacing: 0

        Item { Layout.fillWidth: true }
        PC3.ToolButton {
            icon.name: "view-refresh"
            enabled: !full.app.refreshing
            display: PC3.AbstractButton.IconOnly
            text: i18n("Refresh usage")
            PC3.ToolTip.text: text
            PC3.ToolTip.visible: hovered
            PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
            onClicked: full.app.refreshNow()
        }
        PC3.ToolButton {
            icon.name: "utilities-terminal"
            display: PC3.AbstractButton.IconOnly
            text: i18n("Open %1 in the home folder", full.app.agentName)
            PC3.ToolTip.text: text
            PC3.ToolTip.visible: hovered
            PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
            onClicked: full.app.openTerminal("", "")
        }
    }
}
