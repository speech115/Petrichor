import AppKit
import SwiftUI

/// The track list as an `NSTableView`. SwiftUI's `Table` hosts a SwiftUI view
/// per cell, and building those made every list take 150–300 ms to open.
struct TrackTable: NSViewRepresentable {
    /// The playlist or entity shown; a new one starts scrolled to the top.
    let listID: UUID?
    let tracks: [Track]
    @Binding var selection: Set<Track.ID>
    @Binding var sortOrder: [KeyPathComparator<Track>]
    let isCustomSort: Bool
    let layout: TrackTableLayout
    let rowSize: TableRowSize
    let showsTrackNumbers: Bool
    let database: DatabaseManager
    let currentTrack: Track?
    let isPlaying: Bool
    let isFavorite: (Track) -> Bool
    let onPlayTrack: (Track) -> Void
    let onTogglePlayPause: () -> Void
    let onPrimaryAction: (Track) -> Void
    let onToggleFavorite: (Track, Bool) -> Void
    let contextMenuItems: ([Track]) -> [ContextMenuItem]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = TrackNSTableView()
        table.style = .inset
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = layout == .standard
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = layout == .standard
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = rowSize.rowHeight
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onReturn = { [weak coordinator] in coordinator?.performPrimaryAction() }

        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        for column in TrackColumn.all {
            table.addTableColumn(column.makeTableColumn(sortable: layout == .standard))
        }

        switch layout {
        case .standard:
            table.autosaveName = "TrackTable"
            table.autosaveTableColumns = true
            let headerMenu = NSMenu()
            headerMenu.delegate = coordinator
            table.headerView?.menu = headerMenu
        case .album:
            table.headerView = nil
        }
        coordinator.applyColumnVisibility(to: table)
        // Connected after the autosave name: restoring the saved columns also
        // restores a saved sort, which must not reach the app's sort state.
        table.dataSource = coordinator
        table.delegate = coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        coordinator.table = table
        coordinator.appliedRowSize = rowSize
        coordinator.applySortIndicator()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: TrackTable
        weak var table: NSTableView?
        var tracks: [Track]
        var appliedRowSize: TableRowSize
        private var isApplyingState = false
        /// A new list opens at its first row once its tracks arrive.
        private var scrollsToTopOnLoad = true

        init(_ parent: TrackTable) {
            self.parent = parent
            self.tracks = parent.tracks
            self.appliedRowSize = parent.rowSize
        }

        func update(with parent: TrackTable) {
            let oldTracks = tracks
            let oldParent = self.parent
            self.parent = parent
            tracks = parent.tracks
            guard let table else { return }

            if oldParent.listID != parent.listID {
                scrollsToTopOnLoad = true
            }

            if appliedRowSize != parent.rowSize {
                appliedRowSize = parent.rowSize
                table.rowHeight = parent.rowSize.rowHeight
                reloadAll()
            } else if oldTracks.count != tracks.count || !oldTracks.elementsEqual(tracks, by: { $0.id == $1.id }) {
                reloadAll()
            } else if oldParent.showsTrackNumbers != parent.showsTrackNumbers {
                reloadAll()
            } else {
                // Same rows: refresh what is on screen (playing state, favorites).
                reloadVisibleRows()
            }

            if parent.selection != selectedIDs() {
                applySelection()
            }
            applySortIndicator()
        }

        /// Keeps the existing row views and refills them: a full `reloadData`
        /// tears every row down and rebuilds it, which is most of a list switch.
        private func reloadAll() {
            guard let table else { return }
            // Rows dropped past the new end must not report a selection change.
            isApplyingState = true
            table.noteNumberOfRowsChanged()
            isApplyingState = false
            if scrollsToTopOnLoad, !tracks.isEmpty {
                scrollsToTopOnLoad = false
                table.scrollRowToVisible(0)
            }
            reloadVisibleRows()
            applySelection()
        }

        /// Refills every row that has a view, including the ones prepared just
        /// outside the visible area for scrolling.
        private func reloadVisibleRows(columns: IndexSet? = nil) {
            guard let table else { return }
            let visible = table.rows(in: table.preparedContentRect.union(table.visibleRect))
            guard visible.length > 0 else { return }
            table.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                columnIndexes: columns ?? IndexSet(integersIn: 0..<table.numberOfColumns)
            )
        }

        private func selectedIDs() -> Set<Track.ID> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { tracks.indices.contains($0) ? tracks[$0].id : nil })
        }

        private func applySelection() {
            guard let table else { return }
            let selection = parent.selection
            let rows = selection.isEmpty
                ? IndexSet()
                : IndexSet(tracks.indices.filter { selection.contains(tracks[$0].id) })
            guard rows != table.selectedRowIndexes else { return }
            isApplyingState = true
            table.selectRowIndexes(rows, byExtendingSelection: false)
            isApplyingState = false
        }

        func applySortIndicator() {
            guard let table, parent.layout == .standard else { return }
            let current = NSSortDescriptor(
                key: TrackSortField.detect(from: parent.sortOrder).rawValue,
                ascending: TrackSortField.isAscending(from: parent.sortOrder)
            )
            let descriptors = parent.isCustomSort ? [] : [current]
            guard table.sortDescriptors != descriptors else { return }
            isApplyingState = true
            table.sortDescriptors = descriptors
            isApplyingState = false
        }

        // MARK: Column visibility

        private var visibleColumnIDs: Set<String> {
            switch parent.layout {
            case .standard:
                return Set(TrackColumn.storedVisibleIDs())
            case .album:
                return ["trackNumber", "title", "artist", "duration"]
            }
        }

        func applyColumnVisibility(to table: NSTableView) {
            let visible = visibleColumnIDs
            for column in table.tableColumns {
                column.isHidden = !visible.contains(column.identifier.rawValue)
            }
        }

        @objc
        private func toggleColumn(_ sender: NSMenuItem) {
            guard let table, let id = sender.representedObject as? String,
                  let column = table.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
            column.isHidden.toggle()
            TrackColumn.storeVisibleIDs(table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue))
            (table as? TrackNSTableView)?.fitColumns(to: table.enclosingScrollView?.contentView.bounds.width ?? table.bounds.width)
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            tracks.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, tracks.indices.contains(row) else { return nil }
            let track = tracks[row]
            let isCurrent = isCurrentTrack(track)
            let font = NSFont.systemFont(ofSize: 13, weight: isCurrent ? .medium : .regular)
            let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: isCurrent ? .medium : .regular)

            switch tableColumn.identifier.rawValue {
            case "title":
                let cell = tableView.reusableCell(TrackTitleCellView.self, id: "title")
                cell.configure(
                    track: track,
                    rowSize: parent.layout == .album ? .compact : parent.rowSize,
                    isCurrent: isCurrent,
                    isPlaying: isCurrent && parent.isPlaying,
                    isSelected: tableView.isRowSelected(row),
                    database: parent.database
                ) { [weak self] in
                    guard let self else { return }
                    if self.isCurrentTrack(track) {
                        self.parent.onTogglePlayPause()
                    } else {
                        self.parent.onPlayTrack(track)
                    }
                }
                return cell
            case "favorite":
                let cell = tableView.reusableCell(FavoriteCellView.self, id: "favorite")
                let isFavorite = parent.isFavorite(track)
                cell.configure(isFavorite: isFavorite) { [weak self] in
                    self?.parent.onToggleFavorite(track, isFavorite)
                }
                return cell
            case "artist":
                let cell = tableView.reusableCell(LinkCellView.self, id: "artist")
                cell.configure(text: track.displayArtist, font: font) { TrackContextMenu.goToArtist(of: track) }
                return cell
            case "album":
                let cell = tableView.reusableCell(LinkCellView.self, id: "album")
                cell.configure(text: track.displayAlbum, font: font) { TrackContextMenu.goToAlbum(of: track) }
                return cell
            case "trackNumber":
                let text = parent.showsTrackNumbers ? track.trackNumber.map(String.init) ?? "" : ""
                return textCell(tableView, "trackNumber", text, digitFont, .secondaryLabelColor, .right)
            case "discNumber":
                return textCell(tableView, "discNumber", track.discNumber.map(String.init) ?? "", digitFont, .secondaryLabelColor)
            case "genre":
                return textCell(tableView, "genre", track.displayGenre, font, .labelColor)
            case "year":
                return textCell(tableView, "year", track.displayYear, font, .labelColor)
            case "composer":
                return textCell(tableView, "composer", track.displayComposer, font, .labelColor)
            case "filename":
                return textCell(tableView, "filename", track.filename, font, .secondaryLabelColor)
            case "dateAdded":
                let text = track.dateAdded.map { Self.dateFormatter.string(from: $0) } ?? ""
                return textCell(tableView, "dateAdded", text, font, .secondaryLabelColor)
            case "duration":
                return textCell(tableView, "duration", HelperUtils.formattedDuration(track.duration), digitFont, .secondaryLabelColor)
            default:
                return nil
            }
        }

        private func textCell(
            _ tableView: NSTableView,
            _ id: String,
            _ text: String,
            _ font: NSFont,
            _ color: NSColor,
            _ alignment: NSTextAlignment = .left
        ) -> NSView {
            let cell = tableView.reusableCell(TextCellView.self, id: id)
            cell.label.stringValue = text
            cell.label.font = font
            cell.label.textColor = color
            cell.label.alignment = alignment
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            // Title cells show a play button on selected rows.
            if let titleIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" }) {
                reloadVisibleRows(columns: [titleIndex])
            }
            guard !isApplyingState else { return }
            parent.selection = selectedIDs()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplyingState,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let field = TrackSortField(rawValue: key) else { return }
            parent.sortOrder = [field.getComparator(ascending: descriptor.ascending)]
        }

        // MARK: Actions

        @objc
        func doubleClicked() {
            guard let table, tracks.indices.contains(table.clickedRow) else { return }
            parent.onPrimaryAction(tracks[table.clickedRow])
        }

        func performPrimaryAction() {
            guard let table, let row = table.selectedRowIndexes.first, tracks.indices.contains(row) else { return }
            parent.onPrimaryAction(tracks[row])
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if menu === table.headerView?.menu {
                for column in table.tableColumns where column.identifier.rawValue != "title" {
                    let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = column.identifier.rawValue
                    item.state = column.isHidden ? .off : .on
                    menu.addItem(item)
                }
                return
            }
            // A right click acts on the clicked row, or on the selection it belongs to;
            // a menu opened from the keyboard or VoiceOver acts on the selection.
            let clicked = table.clickedRow
            let rows = tracks.indices.contains(clicked) && !table.selectedRowIndexes.contains(clicked)
                ? [clicked]
                : table.selectedRowIndexes
            guard !rows.isEmpty else { return }
            for item in parent.contextMenuItems(rows.map { tracks[$0] }) {
                menu.addItem(Self.menuItem(item))
            }
        }

        private static func menuItem(_ item: ContextMenuItem) -> NSMenuItem {
            switch item {
            case let .button(title, _, _, action):
                let menuItem = ClosureMenuItem(title: title, action: action)
                menuItem.image = item.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                return menuItem
            case let .menu(title, _, items):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.image = item.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                let submenu = NSMenu(title: title)
                items.forEach { submenu.addItem(Self.menuItem($0)) }
                menuItem.submenu = submenu
                return menuItem
            case .divider:
                return .separator()
            }
        }

        // MARK: Helpers

        private func isCurrentTrack(_ track: Track) -> Bool {
            guard let current = parent.currentTrack else { return false }
            if let currentID = current.trackId, let trackID = track.trackId {
                return currentID == trackID
            }
            return current.url.path == track.url.path
        }

        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter
        }()
    }
}

// MARK: - Columns

private struct TrackColumn {
    let id: String
    let title: String
    let field: TrackSortField
    let minWidth: CGFloat
    var width: CGFloat?
    var maxWidth: CGFloat?
    let isVisibleByDefault: Bool

    static let all: [TrackColumn] = [
        TrackColumn(id: "trackNumber", title: "#", field: .trackNumber, minWidth: 20, width: 28, maxWidth: 44, isVisibleByDefault: false),
        TrackColumn(id: "favorite", title: "★", field: .favorite, minWidth: 18, width: 18, maxWidth: 18, isVisibleByDefault: false),
        TrackColumn(id: "discNumber", title: String(localized: "Disc"), field: .discNumber, minWidth: 20, isVisibleByDefault: false),
        TrackColumn(id: "title", title: String(localized: "Title"), field: .title, minWidth: 200, isVisibleByDefault: true),
        TrackColumn(id: "artist", title: String(localized: "Artist"), field: .artist, minWidth: 100, isVisibleByDefault: true),
        TrackColumn(id: "album", title: String(localized: "Album"), field: .album, minWidth: 100, isVisibleByDefault: true),
        TrackColumn(id: "genre", title: String(localized: "Genre"), field: .genre, minWidth: 80, isVisibleByDefault: false),
        TrackColumn(id: "year", title: String(localized: "Year"), field: .year, minWidth: 40, isVisibleByDefault: true),
        TrackColumn(id: "composer", title: String(localized: "Composer"), field: .composer, minWidth: 100, isVisibleByDefault: false),
        TrackColumn(id: "filename", title: String(localized: "Filename"), field: .filename, minWidth: 200, isVisibleByDefault: false),
        TrackColumn(id: "dateAdded", title: String(localized: "Date Added"), field: .dateAdded, minWidth: 100, isVisibleByDefault: false),
        TrackColumn(
            id: "duration",
            title: String(localized: "Duration"),
            field: .duration,
            minWidth: 40,
            width: 50,
            maxWidth: 100,
            isVisibleByDefault: true
        ),
    ]

    func makeTableColumn(sortable: Bool) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.minWidth = minWidth
        column.width = width ?? minWidth * 1.5
        if let maxWidth { column.maxWidth = maxWidth }
        if sortable {
            column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: true)
        }
        return column
    }

    private static let visibleKey = "trackTableVisibleColumns"
    /// SwiftUI `Table` customization, read once to carry the user's columns over.
    private static let legacyCustomizationKey = "trackTableColumnCustomizationData"

    static func storedVisibleIDs() -> [String] {
        let defaults = UserDefaults.standard
        if let stored = defaults.stringArray(forKey: visibleKey) {
            return stored
        }
        var visible = all.filter(\.isVisibleByDefault).map(\.id)
        if let data = defaults.data(forKey: legacyCustomizationKey),
           let legacy = try? JSONDecoder().decode(TableColumnCustomization<Track>.self, from: data) {
            visible = all.compactMap { column in
                switch legacy[visibility: column.id] {
                case .visible: return column.id
                case .hidden: return nil
                default: return column.isVisibleByDefault ? column.id : nil
                }
            }
        }
        storeVisibleIDs(visible)
        defaults.removeObject(forKey: legacyCustomizationKey)
        return visible
    }

    static func storeVisibleIDs(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: visibleKey)
    }
}

// MARK: - Table and rows

private final class TrackNSTableView: NSTableView {
    var onReturn: (() -> Void)?
    private var hasFittedColumns = false

    override func layout() {
        super.layout()
        // Columns are added before the table has a width; fit them once it does.
        guard !hasFittedColumns, let width = enclosingScrollView?.contentView.bounds.width, width > 0 else { return }
        hasFittedColumns = true
        fitColumns(to: width)
    }

    /// Shrinks the visible columns proportionally so none falls off the right edge.
    func fitColumns(to width: CGFloat) {
        let visible = tableColumns.filter { !$0.isHidden }
        let spacing = intercellSpacing.width * CGFloat(visible.count)
        let total = visible.reduce(0) { $0 + $1.width }
        guard total + spacing > width, total > 0 else { return }
        let scale = (width - spacing) / total
        for column in visible {
            column.width = max(column.minWidth, column.width * scale)
        }
    }

    /// Lets a click on an artist or album name reach its cell instead of selecting the row.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let link = responder as? LinkCellView, let event, event.type == .leftMouseDown {
            return link.isOverText(event)
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func keyDown(with event: NSEvent) {
        // Return and Enter play the selection, as the SwiftUI table's primary action did.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private extension NSTableView {
    func reusableCell<Cell: NSTableCellView>(_ type: Cell.Type, id: String) -> Cell {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let cell = makeView(withIdentifier: identifier, owner: nil) as? Cell {
            return cell
        }
        let cell = Cell()
        cell.identifier = identifier
        return cell
    }
}

private extension NSImage {
    /// Configured symbols are looked up once: resolving one per cell shows up when a list opens.
    @MainActor private static var symbols: [String: NSImage] = [:]

    @MainActor
    static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)-\(size)"
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        symbols[key] = image
        return image
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @MainActor
    @objc
    private func run() {
        handler()
    }
}

// MARK: - Cells

private class TextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 2, y: (bounds.height - height) / 2, width: bounds.width - 4, height: height)
    }
}

/// Artist and album names: underlined with a pointing hand on hover, as in Apple Music.
private final class LinkCellView: TextCellView {
    private var action: (() -> Void)?
    private var text = ""
    private var font = NSFont.systemFont(ofSize: 13)
    private var isHovered = false {
        didSet { if oldValue != isHovered { render() } }
    }
    private var trackingArea: NSTrackingArea?

    func configure(text: String, font: NSFont, action: @escaping () -> Void) {
        self.text = text
        self.font = font
        self.action = action
        isHovered = false
        render()
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    private func render() {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        if isHovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        label.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
    }

    private var textRect: NSRect {
        let width = min(label.attributedStringValue.size().width + 4, label.frame.width)
        return NSRect(x: label.frame.minX, y: label.frame.minY, width: width, height: label.frame.height)
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: textRect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(textRect, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    func isOverText(_ event: NSEvent) -> Bool {
        textRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The cell, not its label, takes the click, so the table asks the cell.
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if isOverText(event) {
            action?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

private final class FavoriteCellView: NSTableCellView {
    private let button = NSButton()
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(tapped)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(isFavorite: Bool, action: @escaping () -> Void) {
        self.action = action
        button.image = .symbol(isFavorite ? Icons.starFill : Icons.star, size: 13)
        button.contentTintColor = isFavorite ? .systemYellow : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        button.frame = bounds
    }

    @objc
    private func tapped() {
        action?()
    }
}

/// Artwork with a play/pause overlay on the current or selected row, then the title.
private final class TrackTitleCellView: NSTableCellView {
    private let artwork = NSImageView()
    private let placeholder = NSImageView()
    private let dimmer = NSView()
    private let playButton = NSButton()
    private let label = NSTextField(labelWithString: "")
    private var rowSize: TableRowSize = .expanded
    private var trackKey: String?
    private var artworkTask: Task<Void, Never>?
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 4
        artwork.layer?.masksToBounds = true
        artwork.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.2).cgColor

        placeholder.image = .symbol(Icons.musicNote, size: 18)
        placeholder.contentTintColor = .secondaryLabelColor

        dimmer.wantsLayer = true
        dimmer.layer?.cornerRadius = 4
        dimmer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor

        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.target = self
        playButton.action = #selector(tapped)

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        [artwork, placeholder, dimmer, playButton, label].forEach(addSubview)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // swiftlint:disable:next function_parameter_count
    func configure(
        track: Track,
        rowSize: TableRowSize,
        isCurrent: Bool,
        isPlaying: Bool,
        isSelected: Bool,
        database: DatabaseManager,
        action: @escaping () -> Void
    ) {
        self.rowSize = rowSize
        self.action = action
        label.stringValue = track.title
        label.font = .systemFont(ofSize: 13, weight: isCurrent ? .bold : .regular)

        let expanded = rowSize == .expanded
        let showsButton = isCurrent || isSelected
        artwork.isHidden = !expanded
        dimmer.isHidden = !(expanded && showsButton)
        playButton.isHidden = !showsButton
        let symbol = isCurrent && isPlaying ? Icons.pauseFill : Icons.playFill
        playButton.image = .symbol(symbol, size: expanded ? 20 : 14)
        playButton.contentTintColor = expanded ? .white : .labelColor

        if expanded {
            loadArtwork(for: track, database: database)
        } else {
            placeholder.isHidden = true
            artworkTask?.cancel()
        }
        needsLayout = true
    }

    private func loadArtwork(for track: Track, database: DatabaseManager) {
        let key = track.id
        let changed = key != trackKey
        trackKey = key
        if let cached = TrackArtworkCache.shared.getCachedImage(for: track) {
            artworkTask?.cancel()
            setArtwork(cached)
            return
        }
        guard changed || artwork.image == nil else { return }
        artworkTask?.cancel()
        setArtwork(nil)
        let albumId = track.albumId
        let trackId = track.trackId
        artworkTask = Task { [weak self] in
            let image = await TrackArtworkCache.shared.loadImage(for: track) {
                database.getArtworkData(albumId: albumId, trackId: trackId)
            }
            guard !Task.isCancelled, let self, self.trackKey == key else { return }
            self.setArtwork(image)
        }
    }

    private func setArtwork(_ image: PlatformImage?) {
        artwork.image = image
        placeholder.isHidden = image != nil || rowSize != .expanded
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        var x: CGFloat = 0
        if rowSize == .expanded {
            let size = ViewDefaults.listArtworkSize
            let box = NSRect(x: x, y: midY - size / 2, width: size, height: size)
            artwork.frame = box
            dimmer.frame = box
            placeholder.frame = box
            playButton.frame = box
            x += size + 8
        } else {
            playButton.frame = NSRect(x: x, y: midY - 10, width: 20, height: 20)
            x += 20 + 8
        }
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: midY - height / 2, width: max(0, bounds.width - x - 2), height: height)
    }

    @objc
    private func tapped() {
        action?()
    }
}

// MARK: - Track Artwork Cache

private final class TrackArtworkCache: @unchecked Sendable {
    static let shared = TrackArtworkCache()
    private let cache = NSCache<NSString, PlatformImage>()
    private let loadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        queue.qualityOfService = .utility
        return queue
    }()

    private static let pixelSize = Int(ViewDefaults.listArtworkSize * 2)
    private static let bytesPerImage = pixelSize * pixelSize * 4

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    private func cacheKey(for track: Track) -> NSString {
        "\(track.trackId?.description ?? track.url.path)-trackCell" as NSString
    }

    func getCachedImage(for track: Track) -> PlatformImage? {
        cache.object(forKey: cacheKey(for: track))
    }

    func loadImage(for track: Track, artworkLoader: (() -> Data?)? = nil) async -> PlatformImage? {
        let key = cacheKey(for: track)

        if let cached = cache.object(forKey: key) {
            return cached
        }

        return await loadQueue.renderArtwork { [self] in
            // Re-check cache — another operation may have loaded it while queued
            if let cached = cache.object(forKey: key) {
                return cached
            }

            // Decode and resize via CGContext to avoid CGImageSource errors
            // under concurrent load from rapid scrolling. Playlist list rows
            // arrive without display-size BLOBs; use the thumbnail when present,
            // otherwise fetch the album/track artwork on demand.
            guard let data = track.displayArtwork ?? artworkLoader?(),
                  let platformImage = PlatformImage(data: data),
                  let cgImage = platformImage.cgImage else {
                return nil
            }

            let size = Self.pixelSize
            guard let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

            guard let resizedCG = context.makeImage() else { return nil }

            let result = NSImage(cgImage: resizedCG, size: NSSize(width: size, height: size))
            cache.setObject(result, forKey: key, cost: Self.bytesPerImage)
            return result
        }
    }
}
