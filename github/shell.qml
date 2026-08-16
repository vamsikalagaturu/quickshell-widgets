import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// GitHub dashboard: unread notifications, review requests, your open pull
// requests (with check state), assigned issues, running/failed Actions, and a
// searchable/sortable repository list.
//
// The data layer (Service.qml + github-fetch) is ported near-verbatim from
// robzolkos/omarchy-github (MIT License, Copyright (c) 2026 Rob Zolkos):
// https://github.com/robzolkos/omarchy-github -- it targets Omarchy Quattro's
// own Quickshell bar (qs.Commons/qs.Ui, a component library this repo does
// not have), so that part -- everything below -- is a fresh implementation
// against this repo's own PanelWindow/Theme conventions, matching the
// feature set and porting the panel's cursor/filter/sort/mark-as-read logic.
//
// j/k or arrows move a single cursor across every section and the repo list,
// Enter opens the selected row on github.com, m marks the selected
// notification read, M arms then confirms "mark all read", / focuses the
// repo filter, r refreshes, Esc closes.
PanelWindow {
    id: win
    visible: false
    color: "transparent"
    // ponytail: no anchors on purpose. wlr-layer-shell centres a surface on
    // whichever axis it isn't anchored to, on the focused output, and it does
    // that in logical pixels -- so fractional scale and rotation come out
    // right for free. Computing margins by hand got both wrong: Hyprland's
    // monitor width/height are raw physical pixels, and Hyprland.focusedMonitor
    // is null until the monitor list has been populated over IPC, so it fell
    // back to win.screen (the laptop) nearly every time.
    exclusionMode: ExclusionMode.Normal
    aboveWindows: true
    focusable: true

    implicitWidth: Theme.s(520)
    implicitHeight: Theme.s(640)

    readonly property int previewCount: 5
    readonly property int expandedCount: 25

    property string query: ""
    property string metricFilter: "all"
    property bool cursorActive: false
    property int cursorIndex: 0
    property bool notificationsExpanded: false
    property bool reviewsExpanded: false
    property bool myPullsExpanded: false
    property bool issuesExpanded: false
    property bool confirmMarkAll: false

    // "dashboard" | "settings" -- , toggles, Esc in settings returns to
    // dashboard rather than closing the panel outright.
    property string mode: "dashboard"
    property var excludedOrgs: []
    // Tab highlights the Settings button; Enter/Space while focused opens it.
    // Only one focusable target exists today, so this is a flag, not a chain.
    property bool settingsFocused: false

    // Lives next to connectivity's network.json / qml_color.json in
    // ~/.config/quickshell, not inside the git-tracked widget directory.
    FileView {
        id: excludedOrgsFile
        path: "/home/batsy/.config/quickshell/github-excluded-orgs.json"
        printErrors: false
        onLoaded: {
            try {
                var parsed = JSON.parse(excludedOrgsFile.text())
                win.excludedOrgs = Array.isArray(parsed) ? parsed : []
            } catch (e) { win.excludedOrgs = [] }
        }
        onLoadFailed: function(error) { win.excludedOrgs = [] }
    }

    function toggleOrgExcluded(org) {
        var list = win.excludedOrgs.slice()
        var idx = list.indexOf(org)
        if (idx >= 0) list.splice(idx, 1)
        else list.push(org)
        win.excludedOrgs = list
        excludedOrgsFile.setText(JSON.stringify(list))
    }

    // Derived from whatever's currently loaded, not from a fixed list --
    // an org you're removed from should stop showing up here on its own.
    readonly property var availableOrgs: {
        var set = ({})
        for (var i = 0; i < github.repositories.length; i++) {
            var owner = String(github.repositories[i].nameWithOwner || "").split("/")[0]
            if (owner !== "") set[owner] = true
        }
        return Object.keys(set).sort()
    }

    readonly property var metricFilters: [
        { id: "all", label: "All" }, { id: "issues", label: "Issues" },
        { id: "prs", label: "PRs" }
    ]

    function sectionRows(rows, expanded) {
        return rows.slice(0, expanded ? win.expandedCount : win.previewCount)
    }

    // Each row is tagged with its section kind so a nested Repeater delegate
    // can tell what it's rendering without reaching up through ids.
    function withKind(kind, rows) {
        var out = []
        for (var i = 0; i < rows.length; i++) {
            var merged = Object.assign({}, rows[i])
            merged._kind = kind
            out.push(merged)
        }
        return out
    }

    // The bottom search bar matches title + "owner/repo" (which already
    // covers org search -- "secorolab" matches every secorolab/* row) against
    // issues, PRs and reviews. Notifications/Actions are left alone: they're
    // an inbox, not something you search.
    function filterRows(rows) {
        var needle = String(win.query || "").trim().toLowerCase()
        if (needle === "") return rows
        return rows.filter(function(row) {
            return String(row.title || "").toLowerCase().indexOf(needle) !== -1
                || String(row.repository || "").toLowerCase().indexOf(needle) !== -1
        })
    }

    function buildSections() {
        var searching = String(win.query || "").trim() !== ""
        var reviews = win.filterRows(github.reviewRequests)
        var myPulls = win.filterRows(github.myPullRequests)
        var issues = win.filterRows(github.assignedIssues)
        return [
            { key: "notifications", title: "UNREAD NOTIFICATIONS",
              rows: win.withKind("notification", win.sectionRows(github.notifications, win.notificationsExpanded)),
              count: github.notifications.length, expanded: win.notificationsExpanded,
              alwaysShow: true, searchable: false, emptyText: "You're all caught up.",
              openUrl: "https://github.com/notifications", markAll: true },
            { key: "reviews", title: "REVIEW REQUESTS",
              rows: win.withKind("review", win.sectionRows(reviews, win.reviewsExpanded)),
              count: reviews.length, expanded: win.reviewsExpanded,
              alwaysShow: false, searchable: true, emptyText: "No matching review requests.",
              openUrl: "https://github.com/pulls/review-requested", markAll: false },
            { key: "mypulls", title: "MY PULL REQUESTS",
              rows: win.withKind("mypull", win.sectionRows(myPulls, win.myPullsExpanded)),
              count: searching ? myPulls.length : Math.max(github.myPullRequestsTotal, github.myPullRequests.length),
              expanded: win.myPullsExpanded,
              alwaysShow: false, searchable: true, emptyText: "No matching pull requests.",
              openUrl: "https://github.com/pulls", markAll: false },
            { key: "issues", title: "ASSIGNED ISSUES",
              rows: win.withKind("issue", win.sectionRows(issues, win.issuesExpanded)),
              count: issues.length, expanded: win.issuesExpanded,
              alwaysShow: false, searchable: true, emptyText: "No matching issues.",
              openUrl: "https://github.com/issues/assigned", markAll: false }
        ]
    }
    readonly property var sections: buildSections()

    function toggleSection(key) {
        if (key === "notifications") win.notificationsExpanded = !win.notificationsExpanded
        else if (key === "reviews") win.reviewsExpanded = !win.reviewsExpanded
        else if (key === "mypulls") win.myPullsExpanded = !win.myPullsExpanded
        else if (key === "issues") win.issuesExpanded = !win.issuesExpanded
    }

    // ---- repositories: filter ----
    // Fixed order: most recently updated first, same as GitHub's own repo
    // list default. No user-facing sort control.
    function filteredRepositories() {
        var needle = String(win.query || "").trim().toLowerCase()
        var rows = []
        for (var i = 0; i < github.repositories.length; i++) {
            var repo = github.repositories[i]
            var owner = String(repo.nameWithOwner || "").split("/")[0]
            if (win.excludedOrgs.indexOf(owner) !== -1) continue
            if (needle !== "" && String(repo.nameWithOwner || repo.name || "").toLowerCase().indexOf(needle) === -1) continue
            if (win.metricFilter === "issues" && Number(repo.issues || 0) <= 0) continue
            if (win.metricFilter === "prs" && Number(repo.prs || 0) <= 0) continue
            rows.push(repo)
        }
        rows.sort(function(a, b) { return String(b.updatedAt).localeCompare(String(a.updatedAt)) })
        return rows.slice(0, 25)
    }
    readonly property var displayedRepositories: filteredRepositories()

    // Repos you've starred -- separate list from owned/org repos above.
    // No per-metric filter chips: the REST starred endpoint doesn't carry
    // an issues/PRs split, only name/stars/updatedAt.
    function filteredStarred() {
        var needle = String(win.query || "").trim().toLowerCase()
        var rows = []
        for (var i = 0; i < github.starredRepositories.length; i++) {
            var repo = github.starredRepositories[i]
            if (needle !== "" && String(repo.nameWithOwner || repo.name || "").toLowerCase().indexOf(needle) === -1) continue
            rows.push(repo)
        }
        return rows.slice(0, 25)
    }
    readonly property var displayedStarred: filteredStarred()

    // ---- keyboard cursor, flattened across every section + repositories ----
    // Each section's footer buttons (Show all / Mark all read / Open in
    // GitHub) get their own cursor targets too, in the same visibility
    // condition as their Rectangle -- otherwise j/k would step onto a
    // target with nothing to highlight.
    function buildCursorTargets() {
        var targets = []
        for (var s = 0; s < win.sections.length; s++) {
            var section = win.sections[s]
            var rows = section.rows
            for (var i = 0; i < rows.length; i++)
                targets.push({ key: rows[i]._kind + ":" + String(rows[i].id || rows[i].url || i), kind: rows[i]._kind, row: rows[i] })
            if (section.count > win.previewCount)
                targets.push({ key: "footer-show:" + section.key, kind: "footer-show", sectionKey: section.key })
            if (section.markAll && section.count > 0)
                targets.push({ key: "footer-markall:" + section.key, kind: "footer-markall", sectionKey: section.key })
            if (section.count > 0 && section.openUrl !== "")
                targets.push({ key: "footer-open:" + section.key, kind: "footer-open", url: section.openUrl })
        }
        var repos = win.displayedRepositories
        for (var j = 0; j < repos.length; j++)
            targets.push({ key: "repository:" + String(repos[j].id || repos[j].url || j), kind: "repository", row: repos[j] })
        var starred = win.displayedStarred
        for (var k = 0; k < starred.length; k++)
            targets.push({ key: "starred:" + String(starred[k].url || k), kind: "starred", row: starred[k] })
        return targets
    }
    readonly property var cursorTargets: buildCursorTargets()
    readonly property var selectedTarget: cursorTargets.length > 0 ? cursorTargets[Math.max(0, Math.min(cursorIndex, cursorTargets.length - 1))] : null

    function selectedKey() { return selectedTarget ? selectedTarget.key : "" }
    function selectKey(key) {
        for (var i = 0; i < cursorTargets.length; i++)
            if (cursorTargets[i].key === key) { win.cursorActive = true; win.cursorIndex = i; return }
    }
    function ensureCursor() {
        if (cursorTargets.length === 0) { win.cursorIndex = 0; return }
        win.cursorIndex = Math.max(0, Math.min(win.cursorIndex, cursorTargets.length - 1))
    }
    function moveCursor(delta) {
        win.cursorActive = true
        if (cursorTargets.length === 0) return
        win.cursorIndex = Math.max(0, Math.min(cursorTargets.length - 1, win.cursorIndex + delta))
    }
    // Any delegate that becomes selected calls this with itself -- works
    // regardless of which Repeater/section it lives in, no flat list needed.
    function scrollIntoView(item) {
        if (!panelFlick || !item) return
        Qt.callLater(function() {
            var point = item.mapToItem(panelFlick.contentItem, 0, 0)
            var margin = Theme.s(8)
            var top = point.y
            var bottom = top + item.height
            var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
            if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
            else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
        })
    }
    // The hint bar only advertises m/M when they'd do something -- both only
    // ever touch the notifications section, wherever the cursor is.
    function cursorSectionKey() {
        var t = win.selectedTarget
        if (!t) return ""
        if (t.kind === "notification") return "notifications"
        return t.sectionKey || ""
    }
    readonly property bool cursorOnNotifications: cursorSectionKey() === "notifications"
    function activateCursor() {
        if (!win.selectedTarget) return
        var t = win.selectedTarget
        if (t.kind === "footer-show") { win.toggleSection(t.sectionKey); return }
        if (t.kind === "footer-markall") { win.armOrConfirmMarkAll(); return }
        if (t.kind === "footer-open") { win.openUrl(t.url); return }
        win.openUrl(t.row.url)
    }
    function markSelectedRead() {
        if (github.loading || github.marking) return
        if (win.selectedTarget && win.selectedTarget.kind === "notification")
            github.markNotificationRead(String(win.selectedTarget.row.id || ""))
    }
    onCursorTargetsChanged: ensureCursor()

    function armOrConfirmMarkAll() {
        if (github.marking) return
        if (!win.confirmMarkAll) {
            win.confirmMarkAll = true
            markAllArmTimer.restart()
            return
        }
        win.confirmMarkAll = false
        markAllArmTimer.stop()
        var prepared = github.prepareMarkAllNotificationsRead()
        if (prepared !== "") github.markAllNotificationsRead(prepared)
    }
    Timer { id: markAllArmTimer; interval: 4000; repeat: false; onTriggered: win.confirmMarkAll = false }
    Connections {
        target: github
        // A pending confirmation must never survive a refresh, or the next
        // click would run a destructive action on stale notification ids.
        function onNotificationsRevisionChanged() { win.confirmMarkAll = false; markAllArmTimer.stop() }
    }

    // ---- row rendering helpers, one delegate shared by every section kind ----
    function checkLabel(checks) {
        if (checks === "SUCCESS") return "checks passing"
        if (checks === "ERROR") return "checks errored"
        if (github.isBrokenCheck(checks)) return "checks failing"
        if (github.isRunningCheck(checks)) return "checks running"
        return "no checks"
    }
    function relativeTime(value) {
        var then = new Date(String(value || "")).getTime()
        if (!isFinite(then)) return ""
        var seconds = Math.max(0, Math.floor((Date.now() - then) / 1000))
        if (seconds < 60) return "just now"
        if (seconds < 3600) return Math.floor(seconds / 60) + "m ago"
        if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago"
        if (seconds < 2592000) return Math.floor(seconds / 86400) + "d ago"
        return Math.floor(seconds / 2592000) + "mo ago"
    }
    function rowGlyph(kind, row) {
        if (kind === "notification") return row.type === "PullRequest" ? "" : "󰍩"
        if (kind === "review") return ""
        if (kind === "mypull") {
            var checks = String(row.checks || "NONE")
            if (github.isBrokenCheck(checks)) return "󰅖"
            if (github.isRunningCheck(checks)) return "󰁮"
            return checks === "SUCCESS" ? "󰄬" : ""
        }
        if (kind === "issue") return ""
        return ""
    }
    function rowTitle(kind, row) {
        return row.title
    }
    function rowDetail(kind, row) {
        if (kind === "notification") return row.repository + " · " + row.reason + " · " + win.relativeTime(row.updatedAt)
        if (kind === "review") return row.repository + (row.draft ? " · draft" : "") + " · review requested · opened " + win.relativeTime(row.createdAt)
        if (kind === "mypull") return row.repository + " #" + row.number + (row.draft ? " · draft" : "") + " · " + win.checkLabel(String(row.checks || "NONE")) + " · opened " + win.relativeTime(row.createdAt)
        if (kind === "issue") return row.repository + " · assigned to you · opened " + win.relativeTime(row.createdAt)
        return ""
    }
    function rowAlarmed(kind, row) {
        return kind === "mypull" && (github.isBrokenCheck(String(row.checks || "NONE")) || github.isRunningCheck(String(row.checks || "NONE")))
    }
    function openUrl(url) {
        var value = String(url || "")
        if (value === "") return
        Quickshell.execDetached(["xdg-open", value])
        win.close()
    }

    // Reopening 5s after you closed it shouldn't refetch -- what's already
    // in memory is still correct. Only a genuinely stale (or first-ever)
    // load pays the ~10-15s fetch; the 900s background timer and 'r' still
    // refresh unconditionally.
    function dataStale() {
        if (github.fetchedAt === "") return true
        var age = Date.now() - Date.parse(github.fetchedAt)
        return !isFinite(age) || age > 60000
    }
    function open() {
        win.visible = true
        win.mode = "dashboard"
        win.settingsFocused = false
        win.cursorActive = false
        win.cursorIndex = 0
        win.confirmMarkAll = false
        markAllArmTimer.stop()
        panelFlick.contentY = 0
        if (win.dataStale()) github.refresh()
        Qt.callLater(function() { panelBg.forceActiveFocus() })
    }
    function close() {
        win.visible = false
        win.mode = "dashboard"
        win.settingsFocused = false
        win.confirmMarkAll = false
        markAllArmTimer.stop()
    }

    // "Owned" only leaves out repos you reach through org membership rather
    // than personal ownership; this is the whole point of a dashboard that's
    // supposed to cover everything waiting on you.
    Service { id: github; settings: ({ repositoryScope: "Owned and organizations" }) }

    Rectangle {
        id: panelBg
        anchors.fill: parent
        radius: Theme.s(18)
        color: "#f20c0e11"
        border.width: 1
        border.color: "#1e2228"
        focus: true

        // Escape is handled by the top-level Shortcut below, not here -- Qt
        // matches Shortcut sequences during shortcut-override, ahead of
        // whatever's focused, so a branch for it here would never fire.
        Keys.onPressed: event => {
            var txt = event.text
            var k = event.key
            if (txt === ",") { win.mode = win.mode === "settings" ? "dashboard" : "settings"; win.settingsFocused = false; event.accepted = true }
            else if (win.mode === "settings") { /* mouse-only in settings, aside from Esc/, above */ }
            else if (k === Qt.Key_Tab) { win.settingsFocused = true; event.accepted = true }
            else if (win.settingsFocused && (k === Qt.Key_Return || k === Qt.Key_Enter || txt === " ")) {
                win.mode = "settings"; win.settingsFocused = false; event.accepted = true
            }
            else if (txt === "j" || k === Qt.Key_Down) { win.settingsFocused = false; win.moveCursor(1); event.accepted = true }
            else if (txt === "k" || k === Qt.Key_Up) { win.settingsFocused = false; win.moveCursor(-1); event.accepted = true }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) { win.activateCursor(); event.accepted = true }
            else if (txt === "m") { win.markSelectedRead(); event.accepted = true }
            else if (txt === "M") { win.armOrConfirmMarkAll(); event.accepted = true }
            else if (txt === "r" || txt === "R") { github.refresh(); event.accepted = true }
            else if (txt === "/") { query.forceActiveFocus(); event.accepted = true }
        }

        Flickable {
            id: panelFlick
            visible: win.mode === "dashboard"
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: scrollTrack.left; anchors.rightMargin: Theme.s(8)
            anchors.bottom: searchBar.top; anchors.bottomMargin: Theme.s(10)
            contentWidth: width
            contentHeight: content.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            // Flickable's own wheel handling scrolls a fixed, small step per
            // event; against a dashboard this tall (up to ~175 rows with
            // every section expanded) that reads as sluggish. Drive contentY
            // from the raw delta instead, with touchpad pixelDelta boosted
            // and mouse-wheel angleDelta converted to a full row's worth.
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                    var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 1.8 : (event.angleDelta.y / 120) * Theme.s(40)
                    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
                    panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY - dy))
                }
            }

            Column {
                id: content
                width: panelFlick.width
                spacing: Theme.s(14)

                Row {
                    width: parent.width
                    Column {
                        width: parent.width - settingsBtn.width - Theme.s(8)
                        spacing: Theme.s(2)
                        Text {
                            text: github.login !== "" ? "GitHub · " + github.login : "GitHub"
                            color: Theme.text
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(15)
                            font.bold: true
                        }
                        Text {
                            width: parent.width
                            text: github.loading ? "Refreshing dashboard…" : (github.state === "ready" ?
                                github.unreadCount + " unread · " + github.reviewRequests.length + " reviews"
                                + (github.failingPullRequestCount > 0 ? " · " + github.failingPullRequestCount + " failing" : "") : github.message)
                            color: Theme.dim
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            wrapMode: Text.WordWrap
                        }
                    }
                    Item { width: Theme.s(8); height: 1 }
                    Rectangle {
                        id: settingsBtn
                        anchors.verticalCenter: parent.verticalCenter
                        width: settingsBtnText.implicitWidth + Theme.s(16); height: Theme.s(22)
                        radius: Theme.s(6)
                        color: "transparent"
                        border.width: win.settingsFocused ? 2 : 1
                        border.color: win.settingsFocused ? Theme.accent : Theme.line
                        Text {
                            id: settingsBtnText
                            anchors.centerIn: parent
                            text: "Settings"
                            color: win.settingsFocused ? Theme.text : Theme.dim
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(10)
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: win.settingsFocused = true
                            onClicked: win.mode = "settings"
                        }
                    }
                }

                Text {
                    visible: github.notificationActionStatus !== ""
                    width: parent.width
                    text: github.notificationActionStatus
                    color: Theme.dim
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                    wrapMode: Text.WordWrap
                }

                Rectangle {
                    visible: github.state !== "ready" || github.warnings.length > 0
                    width: parent.width
                    implicitHeight: statusText.implicitHeight + Theme.s(14)
                    radius: Theme.s(8)
                    color: "#332e1a1a"
                    border.width: 1
                    border.color: Theme.danger

                    Text {
                        id: statusText
                        anchors.fill: parent
                        anchors.margins: Theme.s(8)
                        text: {
                            if (github.state !== "ready") return github.message
                            var summary = "Partial results · " + String(github.warnings[0] || "A GitHub request failed.")
                            if (github.warnings.length > 1) summary += " · " + (github.warnings.length - 1) + " more"
                            return summary
                        }
                        color: github.state === "ready" ? Theme.dim : Theme.danger
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(11)
                        wrapMode: Text.WordWrap
                    }
                }

                Repeater {
                    model: win.sections
                    delegate: Column {
                        required property var modelData
                        width: content.width
                        spacing: Theme.s(6)
                        visible: modelData.alwaysShow || modelData.count > 0
                            || (modelData.searchable && win.query.trim() !== "")

                        Rectangle { width: parent.width; height: 1; color: Theme.line }

                        Text {
                            text: modelData.title + "  " + modelData.count
                            color: Theme.muted
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(10)
                            font.bold: true
                        }

                        Text {
                            visible: modelData.count === 0 && modelData.emptyText !== ""
                            width: parent.width
                            text: modelData.emptyText
                            color: Theme.dim
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.s(2)
                            Repeater {
                                model: modelData.rows
                                delegate: Rectangle {
                                    id: rowItem
                                    required property var modelData
                                    required property int index
                                    readonly property string rowKey: modelData._kind + ":" + String(modelData.id || modelData.url || index)
                                    readonly property bool selected: win.selectedKey() === rowKey
                                    onSelectedChanged: if (selected && win.cursorActive) win.scrollIntoView(rowItem)
                                    width: parent.width
                                    implicitHeight: rowLayout.implicitHeight + Theme.s(12)
                                    height: implicitHeight
                                    radius: Theme.s(6)
                                    color: selected ? Theme.surfaceAlt : "transparent"
                                    border.width: selected ? 1 : 0
                                    border.color: Theme.accent

                                    // Stops short of markReadBtn rather than anchors.fill: parent --
                                    // a disabled child MouseArea (busy/loading) doesn't block clicks,
                                    // it lets them fall through to whatever's underneath. Without this
                                    // margin, clicking "mark read" while a fetch is in flight would
                                    // silently open the row's URL and close the panel instead.
                                    MouseArea {
                                        anchors.left: parent.left
                                        anchors.right: markReadBtn.visible ? markReadBtn.left : parent.right
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: win.selectKey(rowItem.rowKey)
                                        onClicked: win.openUrl(rowItem.modelData.url)
                                    }

                                    Row {
                                        id: rowLayout
                                        anchors.left: parent.left; anchors.leftMargin: Theme.s(8)
                                        anchors.right: markReadBtn.visible ? markReadBtn.left : parent.right
                                        anchors.rightMargin: Theme.s(8)
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.s(8)

                                        Text {
                                            width: Theme.s(16)
                                            text: win.rowGlyph(rowItem.modelData._kind, rowItem.modelData)
                                            color: win.rowAlarmed(rowItem.modelData._kind, rowItem.modelData) ? Theme.danger : Theme.dim
                                            font.family: Theme.mono
                                            font.pixelSize: Theme.s(13)
                                            horizontalAlignment: Text.AlignHCenter
                                        }

                                        Column {
                                            width: rowLayout.width - Theme.s(16) - Theme.s(8)
                                            spacing: Theme.s(1)
                                            Text {
                                                width: parent.width
                                                text: win.rowTitle(rowItem.modelData._kind, rowItem.modelData)
                                                textFormat: Text.PlainText
                                                color: Theme.text
                                                font.family: Theme.mono
                                                font.pixelSize: Theme.s(12)
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                width: parent.width
                                                text: win.rowDetail(rowItem.modelData._kind, rowItem.modelData)
                                                textFormat: Text.PlainText
                                                color: Theme.dim
                                                font.family: Theme.mono
                                                font.pixelSize: Theme.s(10)
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }

                                    Rectangle {
                                        id: markReadBtn
                                        readonly property bool actionable: !github.loading && !github.marking
                                        visible: rowItem.modelData._kind === "notification"
                                        opacity: actionable ? 1 : 0.35
                                        anchors.right: parent.right; anchors.rightMargin: Theme.s(6)
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Theme.s(22); height: Theme.s(22)
                                        radius: Theme.s(4)
                                        color: "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: github.markingNotificationId === String(rowItem.modelData.id || "") ? "󰄐" : "󰄬"
                                            color: Theme.dim
                                            font.family: Theme.mono
                                            font.pixelSize: Theme.s(12)
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            enabled: markReadBtn.actionable
                                            cursorShape: Qt.PointingHandCursor
                                            onEntered: win.selectKey(rowItem.rowKey)
                                            onClicked: github.markNotificationRead(String(rowItem.modelData.id || ""))
                                        }
                                    }
                                }
                            }
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.s(10)
                            visible: modelData.count > win.previewCount
                                || (modelData.count > 0 && modelData.openUrl !== "")
                                || (modelData.markAll && modelData.count > 0)

                            Rectangle {
                                id: showMoreBtn
                                readonly property string footerKey: "footer-show:" + modelData.key
                                readonly property bool selected: win.selectedKey() === footerKey
                                onSelectedChanged: if (selected && win.cursorActive) win.scrollIntoView(showMoreBtn)
                                visible: modelData.count > win.previewCount
                                width: showMoreText.implicitWidth + Theme.s(16); height: Theme.s(22)
                                radius: Theme.s(6)
                                color: "transparent"
                                border.width: selected ? 2 : 1; border.color: selected ? Theme.accent : Theme.line
                                Text {
                                    id: showMoreText
                                    anchors.centerIn: parent
                                    text: modelData.expanded ? "Show less" : (modelData.count > win.expandedCount ? "Show 25" : "Show all " + modelData.count)
                                    color: Theme.dim
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(10)
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: win.selectKey(showMoreBtn.footerKey)
                                    onClicked: win.toggleSection(modelData.key)
                                }
                            }

                            Rectangle {
                                id: markAllBtn
                                readonly property string footerKey: "footer-markall:" + modelData.key
                                readonly property bool selected: win.selectedKey() === footerKey
                                onSelectedChanged: if (selected && win.cursorActive) win.scrollIntoView(markAllBtn)
                                visible: modelData.markAll && modelData.count > 0
                                opacity: github.marking ? 0.5 : 1
                                width: markAllText.implicitWidth + Theme.s(16); height: Theme.s(22)
                                radius: Theme.s(6)
                                color: "transparent"
                                border.width: selected ? 2 : 1
                                border.color: win.confirmMarkAll ? Theme.warn : (selected ? Theme.accent : Theme.line)
                                Text {
                                    id: markAllText
                                    anchors.centerIn: parent
                                    text: github.marking ? "Marking…" : (win.confirmMarkAll ? "Confirm?" : "Mark all read")
                                    color: win.confirmMarkAll ? Theme.warn : Theme.dim
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(10)
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !github.marking
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: win.selectKey(markAllBtn.footerKey)
                                    onClicked: win.armOrConfirmMarkAll()
                                }
                            }

                            Rectangle {
                                id: openBtn
                                readonly property string footerKey: "footer-open:" + modelData.key
                                readonly property bool selected: win.selectedKey() === footerKey
                                onSelectedChanged: if (selected && win.cursorActive) win.scrollIntoView(openBtn)
                                visible: modelData.count > 0 && modelData.openUrl !== ""
                                width: openText.implicitWidth + Theme.s(16); height: Theme.s(22)
                                radius: Theme.s(6)
                                color: "transparent"
                                border.width: selected ? 2 : 1; border.color: selected ? Theme.accent : Theme.line
                                Text {
                                    id: openText
                                    anchors.centerIn: parent
                                    text: "Open in GitHub  "
                                    color: Theme.dim
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(10)
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: win.selectKey(openBtn.footerKey)
                                    onClicked: win.openUrl(modelData.openUrl)
                                }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.line }

                Text {
                    text: (github.fetchedRepositoryScope === "owned" ? "OWNED REPOSITORIES  " : "REPOSITORIES  ") + win.displayedRepositories.length + "/" + github.repositories.length
                    color: Theme.muted
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(10)
                    font.bold: true
                }

                Flickable {
                    width: parent.width
                    height: filterRow.implicitHeight
                    contentWidth: filterRow.implicitWidth
                    contentHeight: height
                    clip: true
                    flickableDirection: Flickable.HorizontalFlick
                    Row {
                        id: filterRow
                        spacing: Theme.s(6)
                        Repeater {
                            model: win.metricFilters
                            delegate: Rectangle {
                                required property var modelData
                                width: filterLabel.implicitWidth + Theme.s(16); height: Theme.s(22)
                                radius: Theme.s(6)
                                color: win.metricFilter === modelData.id ? Theme.accentDim : "transparent"
                                border.width: 1; border.color: win.metricFilter === modelData.id ? Theme.accent : Theme.line
                                Text {
                                    id: filterLabel
                                    anchors.centerIn: parent
                                    text: modelData.label
                                    color: win.metricFilter === modelData.id ? Theme.text : Theme.dim
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(10)
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.metricFilter = modelData.id }
                            }
                        }
                    }
                }

                Text {
                    visible: win.displayedRepositories.length === 0
                    width: parent.width
                    text: github.repositories.length === 0 ? "No repositories loaded." : "No repositories match these filters."
                    color: Theme.dim
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                    horizontalAlignment: Text.AlignHCenter
                }

                Column {
                    width: parent.width
                    spacing: Theme.s(2)
                    Repeater {
                        model: win.displayedRepositories
                        delegate: Rectangle {
                            id: repoItem
                            required property var modelData
                            required property int index
                            readonly property string rowKey: "repository:" + String(modelData.id || modelData.url || index)
                            readonly property bool selected: win.selectedKey() === rowKey
                            onSelectedChanged: if (selected && win.cursorActive) win.scrollIntoView(repoItem)
                            width: parent.width
                            implicitHeight: repoLayout.implicitHeight + Theme.s(12)
                            height: implicitHeight
                            radius: Theme.s(6)
                            color: selected ? Theme.surfaceAlt : "transparent"
                            border.width: selected ? 1 : 0
                            border.color: Theme.accent

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: win.selectKey(repoItem.rowKey)
                                onClicked: win.openUrl(repoItem.modelData.url)
                            }

                            Column {
                                id: repoLayout
                                anchors.left: parent.left; anchors.leftMargin: Theme.s(8)
                                anchors.right: parent.right; anchors.rightMargin: Theme.s(8)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.s(1)
                                Text {
                                    width: parent.width
                                    text: repoItem.modelData.nameWithOwner
                                    textFormat: Text.PlainText
                                    color: Theme.text
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(12)
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: {
                                        var repo = repoItem.modelData
                                        var parts = ["Issues " + Number(repo.issues || 0),
                                                     "PRs " + Number(repo.prs || 0),
                                                     "Stars " + Number(repo.stars || 0)]
                                        if (Number(repo.activeActions || 0) > 0) parts.push("Actions " + Number(repo.activeActions))
                                        parts.push("updated " + win.relativeTime(repo.updatedAt))
                                        return parts.join("  ·  ")
                                    }
                                    color: Theme.dim
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(10)
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.line }

                Text {
                    text: "STARRED REPOSITORIES  " + win.displayedStarred.length + "/" + github.starredRepositories.length
                    color: Theme.muted
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(10)
                    font.bold: true
                }

                Text {
                    visible: win.displayedStarred.length === 0
                    width: parent.width
                    text: github.starredRepositories.length === 0 ? "No starred repositories loaded." : "No starred repositories match this search."
                    color: Theme.dim
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                    horizontalAlignment: Text.AlignHCenter
                }

                Column {
                    width: parent.width
                    spacing: Theme.s(2)
                    Repeater {
                        model: win.displayedStarred
                        delegate: Rectangle {
                            id: starredItem
                            required property var modelData
                            required property int index
                            readonly property string rowKey: "starred:" + String(modelData.url || index)
                            readonly property bool selected: win.selectedKey() === rowKey
                            onSelectedChanged: if (selected && win.cursorActive) win.scrollIntoView(starredItem)
                            width: parent.width
                            implicitHeight: starredLayout.implicitHeight + Theme.s(12)
                            height: implicitHeight
                            radius: Theme.s(6)
                            color: selected ? Theme.surfaceAlt : "transparent"
                            border.width: selected ? 1 : 0
                            border.color: Theme.accent

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: win.selectKey(starredItem.rowKey)
                                onClicked: win.openUrl(starredItem.modelData.url)
                            }

                            Column {
                                id: starredLayout
                                anchors.left: parent.left; anchors.leftMargin: Theme.s(8)
                                anchors.right: parent.right; anchors.rightMargin: Theme.s(8)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.s(1)
                                Text {
                                    width: parent.width
                                    text: starredItem.modelData.nameWithOwner
                                    textFormat: Text.PlainText
                                    color: Theme.text
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(12)
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: "Stars " + Number(starredItem.modelData.stars || 0) + "  ·  updated " + win.relativeTime(starredItem.modelData.updatedAt)
                                    color: Theme.dim
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(10)
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: github.rateLimit && github.rateLimit.remaining !== undefined
                    width: parent.width
                    text: "API requests remaining: " + (github.rateLimit ? github.rateLimit.remaining : "")
                        + (github.fetchedAt !== "" ? " · updated " + win.relativeTime(github.fetchedAt) : "")
                    color: Theme.muted
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(9)
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        Flickable {
            id: settingsFlick
            visible: win.mode === "settings"
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: hintSep.top; anchors.bottomMargin: Theme.s(10)
            contentWidth: width
            contentHeight: settingsContent.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            Column {
                id: settingsContent
                width: settingsFlick.width
                spacing: Theme.s(10)

                Text {
                    text: "SETTINGS"
                    color: Theme.text
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(15)
                    font.bold: true
                }
                Text {
                    width: parent.width
                    text: "Organizations excluded from the repository list below. Click to toggle."
                    color: Theme.dim
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                    wrapMode: Text.WordWrap
                }

                Rectangle { width: parent.width; height: 1; color: Theme.line }

                Text {
                    visible: win.availableOrgs.length === 0
                    width: parent.width
                    text: "No organizations loaded yet."
                    color: Theme.dim
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                    horizontalAlignment: Text.AlignHCenter
                }

                Column {
                    width: parent.width
                    spacing: Theme.s(2)
                    Repeater {
                        model: win.availableOrgs
                        delegate: Rectangle {
                            id: orgRow
                            required property string modelData
                            readonly property bool excluded: win.excludedOrgs.indexOf(modelData) !== -1
                            width: settingsContent.width
                            height: Theme.s(30)
                            radius: Theme.s(6)
                            color: "transparent"

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: win.toggleOrgExcluded(orgRow.modelData)
                            }

                            Row {
                                anchors.left: parent.left; anchors.leftMargin: Theme.s(4)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.s(10)
                                Rectangle {
                                    width: Theme.s(16); height: Theme.s(16)
                                    radius: Theme.s(3)
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: orgRow.excluded ? "transparent" : Theme.accentDim
                                    border.width: 1
                                    border.color: orgRow.excluded ? Theme.line : Theme.accent
                                    Text {
                                        visible: !orgRow.excluded
                                        anchors.centerIn: parent
                                        text: "✓"
                                        color: Theme.text
                                        font.pixelSize: Theme.s(10)
                                    }
                                }
                                Text {
                                    text: orgRow.modelData
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: orgRow.excluded ? Theme.dim : Theme.text
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(12)
                                }
                                Text {
                                    visible: orgRow.excluded
                                    text: "excluded"
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: Theme.muted
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(10)
                                }
                            }
                        }
                    }
                }
            }
        }

        ScrollTrack {
            id: scrollTrack
            flick: panelFlick
            anchors.right: parent.right; anchors.rightMargin: Theme.s(6)
            anchors.top: panelFlick.top
            anchors.bottom: panelFlick.bottom
        }

        // Pinned above the hint bar, outside the scrolling content -- always
        // visible regardless of scroll position, unlike the old repo-only box
        // that lived inside the Flickable. Drives issues/PRs/repos filtering
        // together (see filterRows/filteredRepositories); "orgs" isn't a
        // separate section, it falls out of matching "owner/repo".
        Rectangle {
            id: searchBar
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: hintSep.top; anchors.bottomMargin: Theme.s(10)
            height: Theme.s(32)
            radius: Theme.s(8)
            color: Theme.surfaceAlt
            border.width: query.activeFocus ? 1 : 0
            border.color: Theme.accent

            Text {
                anchors.left: parent.left; anchors.leftMargin: Theme.s(10)
                anchors.verticalCenter: parent.verticalCenter
                visible: win.query.length === 0
                text: "Search issues, PRs, repos, orgs  /"
                color: Theme.muted
                font.family: Theme.mono
                font.pixelSize: Theme.s(11)
            }

            TextInput {
                id: query
                anchors.fill: parent
                anchors.leftMargin: Theme.s(10)
                anchors.rightMargin: Theme.s(10)
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.text
                font.family: Theme.mono
                font.pixelSize: Theme.s(11)
                selectionColor: Theme.accentDim
                clip: true
                activeFocusOnTab: false
                onTextChanged: win.query = text
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        query.text = ""
                        win.query = ""
                        panelBg.forceActiveFocus()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        panelBg.forceActiveFocus()
                        event.accepted = true
                    }
                }
            }
        }

        Rectangle {
            id: hintSep
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: hintBar.top; anchors.bottomMargin: Theme.s(8)
            height: 1
            color: Theme.line
        }
        Text {
            id: hintBar
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(12)
            elide: Text.ElideRight
            text: win.mode === "settings"
                ? "click to toggle an org · , or Esc back to dashboard"
                : win.cursorOnNotifications
                ? "j/k move · Enter open · m mark read · M mark all · / search · , settings · r refresh · Esc close"
                : "j/k move · Enter open · / search · , settings · r refresh · Esc close"
            color: Theme.dim
            font.family: Theme.mono
            font.pixelSize: Theme.s(10)
        }
    }

    Shortcut {
        sequence: "Esc"
        onActivated: {
            if (win.mode === "settings") win.mode = "dashboard"
            else win.close()
        }
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "toggle-github"
        description: "Toggle GitHub dashboard"
        onPressed: {
            if (win.visible) win.close()
            else win.open()
        }
    }

    HyprlandFocusGrab {
        active: win.visible
        windows: [win]
    }
}
