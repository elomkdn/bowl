import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami

// A little fish in a round bowl, pixel art in Catppuccin Mocha. The water is the gauge:
// `level` is the share of the quota left, 9 rows of it, in the quota's color. The fish
// swims and blows bubbles at rest, darts about while an agent works, comes up to the
// surface under the mouse, lingers near the bottom when the quota runs low, sleeps on
// the pebbles, and leaps out of the dry bowl at the limit.
Canvas {
    id: bowl

    property string mood: "idle"   // idle work wave tired sleep ko
    property real level: 1

    readonly property int cols: 16
    readonly property int rows: 18
    readonly property color glass: "#9399b2"     // overlay2
    readonly property color air: "#313244"       // surface0, the empty part of the bowl
    readonly property color shine: "#cdd6f4"     // text
    readonly property color pebble: "#585b70"    // surface2
    readonly property color pebbleLight: "#7f849c" // overlay1
    readonly property color weed: "#a6e3a1"      // green
    readonly property color bubble: "#f5e0dc"    // rosewater
    readonly property color zzz: "#b4befe"       // lavender
    readonly property color eye: "#11111b"       // crust
    readonly property color fishBody: "#fab387"  // peach
    readonly property color fishFin: "#eba0ac"   // maroon
    readonly property color paleBody: "#cdd6f4"  // text, the fish in peach or red water
    readonly property color paleFin: "#f5c2e7"   // pink
    property color water: "#94e2d5"              // teal, the quota's color comes from main.qml
    readonly property bool motion: Kirigami.Units.longDuration > 0

    property int frame: 0
    property int swim: 0   // the fish's 10 steps, there and back
    property bool blink: false

    implicitWidth: cols * 2
    implicitHeight: rows * 2
    smooth: false

    Behavior on level {
        enabled: bowl.motion
        NumberAnimation { duration: 1400; easing.type: Easing.InOutQuad }
    }

    onMoodChanged: { frame = 0; requestPaint() }
    onLevelChanged: requestPaint()
    onWaterChanged: requestPaint()
    onFrameChanged: requestPaint()
    onSwimChanged: requestPaint()
    onBlinkChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Screen.onDevicePixelRatioChanged: requestPaint()
    onVisibleChanged: requestPaint()

    Timer {
        running: bowl.visible && bowl.motion
        repeat: true
        interval: bowl.mood === "wave" ? 200 : bowl.mood === "work" ? 280
            : bowl.mood === "tired" ? 1000 : 650
        onTriggered: {
            bowl.frame = (bowl.frame + 1) % 12
            if (bowl.mood !== "sleep") bowl.swim = (bowl.swim + 1) % 10
        }
    }
    Timer {
        running: bowl.visible && bowl.motion && (bowl.mood === "idle" || bowl.mood === "tired")
        repeat: true
        interval: 3800
        onTriggered: { bowl.blink = true; blinkEnd.restart() }
    }
    Timer { id: blinkEnd; interval: 450; onTriggered: bowl.blink = false }

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        // The canvas is in logical pixels and Qt renders it at the screen's density: each dot
        // is a whole number of device pixels, and the drawing sits on the device pixel grid
        const dpr = Screen.devicePixelRatio
        const unit = Math.max(1, Math.floor(Math.min(width / cols, height / rows) * dpr + 0.001)) / dpr
        const ox = Math.floor((width - unit * cols) / 2 * dpr) / dpr
        const oy = Math.floor((height - unit * rows) / 2 * dpr) / dpr
        const f = motion ? frame : 0
        const sw = motion ? swim : 2
        function px(x, y, c, w, h) {
            ctx.fillStyle = c
            ctx.fillRect(ox + x * unit, oy + y * unit, (w || 1) * unit, (h || 1) * unit)
        }

        // The fish, 5 dots by 3: a forked tail that flaps, a fin on its back, an eye
        // Peach, or pale where the water itself turns peach or red
        const warm = mood !== "ko" && (Qt.colorEqual(water, "#fab387") || Qt.colorEqual(water, "#f38ba8"))
        const body = warm ? paleBody : fishBody
        const fin = warm ? paleFin : fishFin
        function drawFish(x, y, right, flap, closed) {
            const at = (dx) => right ? x + dx : x + 4 - dx
            if (flap) px(at(0), y + 1, fin)
            else { px(at(0), y, fin); px(at(0), y + 2, fin) }
            px(at(2), y, fin)                                        // back fin
            px(right ? x + 1 : x, y + 1, body, 4, 1)
            px(right ? x + 2 : x + 1, y + 2, body, 2, 1)             // belly
            px(at(3), y + 1, closed ? fin : eye)
        }
        // Going right for 5 steps, then back
        function fishAt(step) {
            return step < 5 ? { x: 3 + step, right: true } : { x: 13 - step, right: false }
        }

        // ---- The bowl: a lip, a round belly, a flat bottom, glass all around
        const inside = [   // row: first and last dot of water inside the glass
            [4, 5, 10], [5, 4, 11], [6, 3, 12],
            [7, 2, 13], [8, 2, 13], [9, 2, 13], [10, 2, 13], [11, 2, 13], [12, 2, 13], [13, 2, 13],
            [14, 3, 12], [15, 4, 11]
        ]
        for (const [y, a, b] of inside) {
            px(a, y, air, b - a + 1, 1)
            px(a - 1, y, glass); px(b + 1, y, glass)
        }
        px(3, 3, glass, 3, 1); px(10, 3, glass, 3, 1)   // the lip
        px(4, 16, glass, 8, 1)                          // the bottom

        // Water: 9 rows from row 14 up, in the quota's color, its surface lighter
        const full = level <= 0 || mood === "ko" ? 0 : Math.max(1, Math.round(Math.min(1, level) * 9))
        const surface = 15 - full
        for (const [y, a, b] of inside)
            if (y >= surface && y <= 14) px(a, y, y === surface ? Qt.lighter(water, 1.18) : water, b - a + 1, 1)

        // Pebbles on the bottom and a strand of weed that sways
        for (let x = 4; x <= 11; x++) px(x, 15, x % 3 === 0 ? pebbleLight : pebble)
        const sway = f % 4 < 2 ? 0 : 1
        px(5, 14, weed); px(5, 13, weed); px(5 + sway, 12, weed)
        px(10, 14, weed); px(10 - sway, 13, weed)

        // A glint on the glass
        px(3, 6, shine); px(2, 7, shine)

        if (mood === "ko") {
            // The bowl is dry: the fish leaps out above it, again and again
            const up = f % 2 === 0
            drawFish(f % 4 < 2 ? 5 : 6, up ? 0 : 1, f % 4 < 2, !up, false)
            return
        }

        // ---- The fish, where the mood puts it
        let fx, fy, right, flap = motion && f % 2 === 1, closed = blink
        if (mood === "sleep") {
            fx = 6; fy = 12; right = true; flap = false; closed = true
        } else {
            const at = fishAt(sw)
            fx = at.x; right = at.right
            if (mood === "wave") fy = Math.max(4, surface - 1)          // its back out of the water
            else if (mood === "tired") fy = 12
            else fy = Math.min(12, Math.max(surface + 1, 9))
            if (full <= 2) fy = 12
        }
        drawFish(fx, fy, right, flap, closed)

        // ---- Bubbles from its mouth rise to the surface and pop; two at a time at work
        if (mood === "idle" || mood === "work" || mood === "wave") {
            const trail = mood === "work" ? [0, 2] : [0]
            for (const lag of trail) {
                const b = (sw + 10 - lag) % 5
                if (b < 1) continue
                const from = fishAt((sw + 10 - lag - b + 1) % 10)
                const by = fy + 1 - b
                if (by > surface) px(from.right ? from.x + 4 : from.x, by, bubble)
            }
        }

        // ---- Its z, beside the lip
        if (mood === "sleep" && f % 3 >= 1) {
            px(13, 0, zzz, 3, 1); px(15, 1, zzz); px(13, 2, zzz); px(13, 3, zzz, 3, 1)
        }
    }
}
