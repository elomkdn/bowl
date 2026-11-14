import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import org.kde.plasma.plasmoid

MouseArea {
    id: compact

    required property var app
    readonly property bool horizontal: Plasmoid.formFactor === 2  // PlasmaCore.Types.Horizontal
    readonly property bool inPanel: Plasmoid.formFactor === 2 || Plasmoid.formFactor === 3

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    onContainsMouseChanged: app.hovered = containsMouse
    onClicked: (mouse) => {
        if (mouse.button === Qt.MiddleButton) app.openTerminal()
        else app.expanded = !app.expanded
    }

    Layout.minimumWidth: horizontal ? mascot.width : -1
    Layout.preferredWidth: horizontal ? mascot.width : -1
    Layout.maximumWidth: horizontal ? mascot.width : -1

    Bowl {
        id: mascot
        anchors.centerIn: parent
        mood: compact.app.mood
        level: 1 - compact.app.usedMain
        water: compact.app.quotaColor(compact.app.usedMain, compact.app.limited)
        // Pixel art: in a panel it takes a whole number of device pixels per dot, as many
        // as fit in about 85% of its thickness, so that it stays sharp
        readonly property real thickness: compact.horizontal ? compact.height : compact.width
        readonly property int units: Math.max(1, Math.floor(thickness * 0.85 * Screen.devicePixelRatio / rows))
        height: compact.inPanel ? units * rows / Screen.devicePixelRatio : Math.min(compact.width, compact.height)
        width: height * cols / rows
    }
}
