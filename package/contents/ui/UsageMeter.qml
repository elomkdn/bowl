import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami

// One quota window on a single line. The small tick marks how much of the window
// has gone by: a bar ahead of its tick means you are consuming faster than the pace.
RowLayout {
    id: meter

    required property string title
    required property var windowData
    required property real windowLength
    required property real used
    required property real now
    required property string resetPhrase
    property color barColor: Kirigami.Theme.highlightColor

    readonly property real elapsed: windowLength > 0 && windowData && windowData.resetsAt > now
        ? Math.max(0, Math.min(1, 1 - (windowData.resetsAt - now) / windowLength)) : 0

    spacing: Kirigami.Units.smallSpacing
    Layout.fillWidth: true

    HoverHandler { id: hover }
    // A model's own limit on the same clock, such as Fable's week, goes in the tooltip
    readonly property string modelsText: (windowData && windowData.models || [])
        .filter(m => m.resetsAt > now)
        .map(m => i18nc("a model's own limit: model, share used", "%1: %2%", m.name, Math.round(m.utilization * 100)))
        .join("\n")
    PC3.ToolTip.text: !windowData ? i18n("Not measured yet") : modelsText ? resetPhrase + "\n" + modelsText : resetPhrase
    PC3.ToolTip.visible: hover.hovered
    PC3.ToolTip.delay: Kirigami.Units.toolTipDelay

    PC3.Label {
        text: meter.title
        font: Kirigami.Theme.smallFont
        opacity: 0.7
    }
    Item {
        Layout.fillWidth: true
        implicitHeight: 8

        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 1
            anchors.bottomMargin: 1
            radius: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.14)
            Rectangle {
                width: parent.width * Math.min(1, meter.used)
                height: parent.height
                radius: 1
                color: meter.barColor
                Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration } }
            }
        }
        Rectangle {
            visible: meter.elapsed > 0
            x: Math.round(parent.width * meter.elapsed) - 1
            width: 2
            height: parent.height
            color: Kirigami.Theme.textColor
        }
    }
    PC3.Label {
        text: meter.windowData ? i18nc("a share of the quota", "%1%", Math.round(meter.used * 100)) : "—"
        font.features: { "tnum": 1 }
    }
}
