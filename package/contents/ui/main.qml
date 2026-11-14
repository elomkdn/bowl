import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string backend: "python3 '"
        + decodeURIComponent(Qt.resolvedUrl("../code/bowl_backend.py").toString().replace("file://", "")) + "'"

    // Quotas and statistics of every agent, refreshed from the backend
    property var agents: ({})
    property real now: Date.now() / 1000
    property bool refreshing: false

    readonly property var agentNames: ({ "claude": "Claude", "codex": "Codex", "opencode": "OpenCode" })
    readonly property var knownAgents: ["claude", "codex", "opencode"]
    readonly property var agentOrder: {
        const saved = Plasmoid.configuration.agentOrder.split(",").filter(a => knownAgents.indexOf(a) >= 0)
        return saved.concat(knownAgents.filter(a => saved.indexOf(a) < 0))
    }
    // Through strings, so that a refresh with nothing new does not rebuild the tabs and lists
    readonly property string installedList: agentOrder.filter(a => agents[a] && agents[a].installed).join(",")
    readonly property var installedAgents: installedList ? installedList.split(",") : []
    readonly property string agent: installedAgents.indexOf(Plasmoid.configuration.agent) >= 0
        ? Plasmoid.configuration.agent : (installedAgents[0] || "claude")
    readonly property string agentName: agentNames[agent]
    readonly property var current: agents[agent] || ({})
    readonly property var windows: current.windows || []
    readonly property var days: current.days || [0, 0, 0, 0, 0, 0, 0]
    readonly property bool hasQuota: windows.length > 0
    readonly property string projectsJson: JSON.stringify(current.projects || [])
    readonly property var projects: JSON.parse(projectsJson)

    // The shortest window, the 5 hours, fills the bowl: it is the one that moves as you work.
    // A longer window at its limit still dries the bowl up, through `limited`.
    readonly property var mainWindow: {
        const span = w => w.minutes || Infinity
        let best = null
        for (const w of windows)
            if (!best || span(w) < span(best)) best = w
        return best
    }
    readonly property real usedMain: currentUse(mainWindow)
    readonly property bool limited: windows.some(w => isLimited(w))
    // Any agent at work wakes the fish up
    readonly property real lastActivity: Math.max(0, ...Object.values(agents).map(a => a.lastActivity || 0))

    property bool hovered: false
    property string launchError: ""
    property real lastLaunch: 0

    readonly property string mood: {
        if (limited) return "ko"
        if (hovered) return "wave"
        if (expanded) return usedMain >= 0.75 ? "tired" : "idle"
        if (usedMain >= 0.75) return "tired"
        if (now - lastActivity < 60) return "work"
        if (lastActivity > 0 && now - lastActivity > 1800) return "sleep"
        return "idle"
    }

    preferredRepresentation: compactRepresentation
    compactRepresentation: CompactView { app: root }
    fullRepresentation: FullView { app: root }
    switchWidth: Kirigami.Units.gridUnit * 16
    switchHeight: Kirigami.Units.gridUnit * 16
    Plasmoid.status: limited ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus

    toolTipMainText: projects.length ? agentName + " · " + projects[0].name : agentName
    toolTipSubText: limited ? i18n("Limit reached. %1", resetPhrase(windows.find(w => isLimited(w))))
        : hasQuota ? windows.map(w => i18nc("window: share used", "%1: %2%", windowLabel(w), Math.round(currentUse(w) * 100))).join("   ·   ")
        : i18n("Show usage")

    component ProjectAction: PlasmaCore.Action {
        property int slot
        readonly property var project: root.projects[slot]
        text: project ? project.name.split("&").join("&&") : ""
        icon.name: "folder"
        visible: !!project
        onTriggered: root.openTerminal(project.path, "")
    }

    Plasmoid.contextualActions: [
        ProjectAction { slot: 0 },
        ProjectAction { slot: 1 },
        ProjectAction { slot: 2 },
        ProjectAction { slot: 3 },
        PlasmaCore.Action {
            text: i18n("Open %1 in the home folder", root.agentName)
            icon.name: "utilities-terminal"
            onTriggered: root.openTerminal("", "")
        },
        PlasmaCore.Action {
            text: i18n("Show usage")
            icon.name: "view-statistics"
            onTriggered: root.expanded = true
        },
        PlasmaCore.Action {
            text: i18n("Refresh usage")
            icon.name: "view-refresh"
            onTriggered: root.refreshNow()
        }
    ]

    onExpandedChanged: {
        if (root.expanded) loadUsage()
        else launchError = ""
    }

    // A quota's color, in Catppuccin Mocha, for the bowl's water and the popup's bars:
    // teal while more than half is left, then yellow, peach from a quarter, red near the end
    function quotaColor(used, limited) {
        return limited || used >= 0.9 ? "#f38ba8" : used >= 0.75 ? "#fab387" : used >= 0.5 ? "#f9e2af" : "#94e2d5"
    }
    function currentUse(w) {
        if (!w) return 0
        return w.resetsAt <= now ? 0 : w.utilization
    }
    function isLimited(w) {
        return !!w && w.resetsAt > now && (w.status === "rejected" || w.utilization >= 1)
    }
    function windowLabel(w) {
        if (!w || !w.minutes) return i18n("Limit")
        if (w.minutes % 1440 === 0) return i18nc("a number of days, short", "%1 d", w.minutes / 1440)
        if (w.minutes % 60 === 0) return i18nc("a number of hours, short", "%1 h", w.minutes / 60)
        return i18nc("a number of minutes, short", "%1 min", w.minutes)
    }
    function formatDate(seconds) {
        return new Date(seconds * 1000).toLocaleString(Qt.locale(), "ddd d MMM HH:mm")
    }
    function resetPhrase(w) {
        if (!w) return ""
        const left = w.resetsAt - now
        if (left <= 0) return i18n("Window free")
        if (left < 3600) return i18n("Resets in %1 min", Math.max(1, Math.round(left / 60)))
        if (left < 86400) return i18n("Resets in %1 h %2", Math.floor(left / 3600), String(Math.floor(left % 3600 / 60)).padStart(2, "0"))
        return i18n("Resets %1", formatDate(w.resetsAt))
    }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        onNewData: (source, data) => {
            disconnectSource(source)
            const callback = callbacks[source]
            delete callbacks[source]
            if (callback) callback(data["stdout"] || "", data["stderr"] || "", data["exit code"])
        }
        function run(command, callback) {
            callbacks[command] = callback
            connectSource(command)
        }
    }

    function loadUsage() {
        exec.run(backend + " usage", (out) => {
            let data
            try { data = JSON.parse(out) } catch (e) { return }
            agents = data.agents || {}
            now = data.now
        })
    }
    function refreshNow() {
        if (agent !== "claude") {  // only Claude's quota can be measured on demand
            loadUsage()
            return
        }
        refreshing = true
        exec.run(backend + " refresh --force", () => {
            refreshing = false
            loadUsage()
        })
    }
    function shellQuote(text) {
        return "'" + text.split("'").join("'\\''") + "'"
    }
    function launchErrorText(code, name) {
        switch (code) {
        case "agent": return i18n("%1 could not be found.", name)
        case "folder": return i18n("This folder no longer exists.")
        default: return i18n("Could not open a terminal.")
        }
    }
    // Without a folder, the agent opens in the last project it worked on. A second click
    // right after the first is ignored: a terminal can take a moment to appear.
    function openTerminal(folder, session) {
        if (Date.now() - lastLaunch < 1500) return
        lastLaunch = Date.now()
        const target = folder === undefined ? (projects.length ? projects[0].path : "") : folder
        const name = agentName
        const notice = i18n("%1 stopped with an error. Press Enter to close this window.", name)
        launchError = ""
        expanded = false
        exec.run(backend + " terminal " + agent + " " + shellQuote(target) + " " + shellQuote(session || "") + " " + shellQuote(notice), (out, err, code) => {
            if (code === 0) return
            launchError = launchErrorText(err.trim(), name)
            expanded = true
        })
    }
    function setAgent(id) {
        if (id !== agent) Plasmoid.configuration.agent = id
    }
    function moveAgent(id, position) {
        const order = installedAgents.filter(a => a !== id)
        order.splice(position, 0, id)
        Plasmoid.configuration.agentOrder = order.concat(knownAgents.filter(a => order.indexOf(a) < 0)).join(",")
    }

    Timer {
        running: true
        repeat: true
        triggeredOnStart: true
        interval: 30000
        onTriggered: root.loadUsage()
    }
    Timer {
        running: true
        repeat: true
        interval: 15000
        onTriggered: root.now = Date.now() / 1000
    }
}
