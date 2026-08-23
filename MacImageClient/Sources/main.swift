import AppKit
import Foundation

private let serviceType = "_npc-image._tcp."
private let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp"]
private let recentFoldersKey = "recentImageSetFolders"
private let chooseFolderCommand = "__choose_folder__"
private let maxSendImageEdge: CGFloat = 2048

final class ImageItem {
    let url: URL
    let thumbnail: NSImage

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }

    init(url: URL, thumbnail: NSImage) {
        self.url = url
        self.thumbnail = thumbnail
    }
}

final class MainWindowController: NSWindowController {
    private let browser = BonjourBrowser()
    private var items: [ImageItem] = []
    private var selectedColorHex = "#000000"
    private var didConfigure = false

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "Searching for display server...")
    private let serverPopup = NSPopUpButton()
    private let folderPopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let colorWell = NSColorWell()
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let dropLabel = NSTextField(labelWithString: "Drag images or folders here")
    private var discoveredTargets: [DisplayTarget] = []
    private var selectedTarget: DisplayTarget?
    private var currentImageSetFolder: URL?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NPC Image Sender"
        window.minSize = NSSize(width: 640, height: 420)
        self.init(window: window)
        configureIfNeeded()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        configureIfNeeded()
    }

    private func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true
        configureUI()
        configureBonjour()
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView.registerForDraggedTypes([.fileURL])

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let sourceRow = NSStackView()
        sourceRow.orientation = .horizontal
        sourceRow.spacing = 10
        sourceRow.alignment = .centerY

        let controlsRow = NSStackView()
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 10
        controlsRow.alignment = .centerY

        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)
        serverPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        folderPopup.target = self
        folderPopup.action = #selector(folderChanged)
        folderPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        colorPopup.addItems(withTitles: ["Black", "White", "Gray", "Custom"])
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged)

        colorWell.color = .black
        colorWell.target = self
        colorWell.action = #selector(colorChanged)

        clearButton.target = self
        clearButton.action = #selector(clearDisplay)

        sourceRow.addArrangedSubview(NSTextField(labelWithString: "Server"))
        sourceRow.addArrangedSubview(serverPopup)
        sourceRow.addArrangedSubview(NSTextField(labelWithString: "Image Set"))
        sourceRow.addArrangedSubview(folderPopup)
        sourceRow.addArrangedSubview(statusLabel)
        sourceRow.addArrangedSubview(NSView())

        controlsRow.addArrangedSubview(NSTextField(labelWithString: "Background"))
        controlsRow.addArrangedSubview(colorPopup)
        controlsRow.addArrangedSubview(colorWell)
        controlsRow.addArrangedSubview(clearButton)
        controlsRow.addArrangedSubview(NSView())

        tableView.headerView = nil
        tableView.rowHeight = 88
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.registerForDraggedTypes([.fileURL])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("image"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        dropLabel.alignment = .center
        dropLabel.textColor = .secondaryLabelColor
        dropLabel.font = .systemFont(ofSize: 20, weight: .medium)
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(dropLabel)

        NSLayoutConstraint.activate([
            dropLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        root.addArrangedSubview(sourceRow)
        root.addArrangedSubview(controlsRow)
        root.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        renderServerPopup()
        renderFolderPopup()
        updateDropLabel()
        updateColor()
    }

    private func configureBonjour() {
        browser.onUpdate = { [weak self] targets in
            DispatchQueue.main.async {
                self?.handleTargetUpdate(targets)
            }
        }
        browser.start()
    }

    private func handleTargetUpdate(_ targets: [DisplayTarget]) {
        discoveredTargets = targets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if let selectedTarget = selectedTarget, discoveredTargets.contains(selectedTarget) {
            self.selectedTarget = discoveredTargets.first { $0 == selectedTarget }
        } else {
            selectedTarget = discoveredTargets.first
        }

        renderServerPopup()
        updateTargetStatus()
    }

    private func renderServerPopup() {
        let selectedBeforeUpdate = selectedTarget
        serverPopup.removeAllItems()

        if discoveredTargets.isEmpty {
            serverPopup.addItem(withTitle: "Searching...")
            serverPopup.isEnabled = false
            return
        }

        serverPopup.isEnabled = true
        for target in discoveredTargets {
            serverPopup.addItem(withTitle: "\(target.name)  \(target.host):\(target.port)")
        }

        if let selectedBeforeUpdate = selectedBeforeUpdate,
           let index = discoveredTargets.firstIndex(of: selectedBeforeUpdate) {
            serverPopup.selectItem(at: index)
        } else {
            serverPopup.selectItem(at: 0)
        }
    }

    @objc private func serverChanged() {
        let index = serverPopup.indexOfSelectedItem
        guard index >= 0 && index < discoveredTargets.count else { return }
        selectedTarget = discoveredTargets[index]
        updateTargetStatus()
    }

    private func updateTargetStatus() {
        if let selectedTarget = selectedTarget {
            statusLabel.stringValue = "Ready: \(selectedTarget.host):\(selectedTarget.port)"
        } else {
            statusLabel.stringValue = "Searching for display server..."
        }
    }

    private func renderFolderPopup() {
        let currentPath = currentImageSetFolder?.standardizedFileURL.path
        folderPopup.removeAllItems()

        folderPopup.addItem(withTitle: "Choose Folder...")
        folderPopup.lastItem?.representedObject = chooseFolderCommand

        let recentFolders = recentFolderURLs()
        if !recentFolders.isEmpty {
            folderPopup.menu?.addItem(.separator())
        }

        for folder in recentFolders {
            folderPopup.addItem(withTitle: "\(folder.lastPathComponent)  \(folder.deletingLastPathComponent().path)")
            folderPopup.lastItem?.representedObject = folder.standardizedFileURL.path
        }

        if let currentPath = currentPath,
           let index = recentFolders.firstIndex(where: { $0.standardizedFileURL.path == currentPath }) {
            folderPopup.selectItem(at: index + 2)
        } else {
            folderPopup.selectItem(at: 0)
        }
    }

    @objc private func folderChanged() {
        guard let representedObject = folderPopup.selectedItem?.representedObject as? String else { return }

        if representedObject == chooseFolderCommand {
            chooseFolder()
            return
        }

        loadImageSetFolder(URL(fileURLWithPath: representedObject))
    }

    private func chooseFolder() {
        guard let window = window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose a folder to use as the current image set."

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = panel.url {
                self.loadImageSetFolder(url)
            } else {
                self.renderFolderPopup()
            }
        }
    }

    @objc private func colorChanged() {
        updateColor()
    }

    private func updateColor() {
        switch colorPopup.titleOfSelectedItem ?? "Black" {
        case "White":
            selectedColorHex = "#ffffff"
            colorWell.color = .white
        case "Gray":
            selectedColorHex = "#808080"
            colorWell.color = .gray
        case "Custom":
            selectedColorHex = colorWell.color.hexString
        default:
            selectedColorHex = "#000000"
            colorWell.color = .black
        }
    }

    @objc private func clearDisplay() {
        guard let target = selectedTarget else {
            statusLabel.stringValue = "No display server selected"
            return
        }

        postJSON(path: "/clear", target: target, payload: ["background_color": selectedColorHex]) { [weak self] result in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = result
            }
        }
    }

    @objc private func tableClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < items.count else { return }
        send(item: items[row])
    }

    private func send(item: ImageItem) {
        guard let target = selectedTarget else {
            statusLabel.stringValue = "No display server selected"
            return
        }

        statusLabel.stringValue = "Preparing \(item.url.lastPathComponent)..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let pngData = try Self.pngData(from: item.url)
                let payload = [
                    "name": "",
                    "image": pngData.base64EncodedString(),
                    "background_color": self.selectedColorHex,
                ]
                self.postJSON(path: "/image", target: target, payload: payload) { [weak self] result in
                    DispatchQueue.main.async {
                        self?.statusLabel.stringValue = result
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "Could not read image: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        let folders = urls.filter { Self.isDirectory($0) }
        if let folder = folders.first {
            folders.forEach(addRecentFolder)
            loadImageSetFolder(folder)
            return
        }

        addImageURLs(urls, replacing: false)
    }

    private func loadImageSetFolder(_ folder: URL) {
        let imageURLs = Self.imageURLs(in: folder)

        currentImageSetFolder = folder
        addRecentFolder(folder)

        if imageURLs.isEmpty {
            items.removeAll()
            tableView.reloadData()
            renderFolderPopup()
            updateDropLabel()
            statusLabel.stringValue = "No supported images in \(folder.lastPathComponent)"
            return
        }

        addImageURLs(imageURLs, replacing: true)
        renderFolderPopup()
        statusLabel.stringValue = "\(items.count) image\(items.count == 1 ? "" : "s") loaded from \(folder.lastPathComponent)"
    }

    private func addImageURLs(_ urls: [URL], replacing: Bool) {
        let imageURLs = urls.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageURLs.isEmpty else {
            statusLabel.stringValue = "No supported image files dropped"
            return
        }

        if replacing {
            items.removeAll()
        } else {
            currentImageSetFolder = nil
            renderFolderPopup()
        }

        for url in imageURLs {
            guard !items.contains(where: { $0.url == url }), let image = NSImage(contentsOf: url) else { continue }
            items.append(ImageItem(url: url, thumbnail: image.thumbnail(maxSize: NSSize(width: 72, height: 72))))
        }

        tableView.reloadData()
        updateDropLabel()
        statusLabel.stringValue = "\(items.count) image\(items.count == 1 ? "" : "s") loaded"
    }

    private func recentFolderURLs() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentFoldersKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }.filter { Self.isDirectory($0) }
    }

    private func addRecentFolder(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: recentFoldersKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(10))
        UserDefaults.standard.set(paths, forKey: recentFoldersKey)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func imageURLs(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func updateDropLabel() {
        dropLabel.isHidden = !items.isEmpty
    }

    private static func pngData(from url: URL) throws -> Data {
        guard let image = NSImage(contentsOf: url) else {
            throw NSError(domain: "NPCImageSender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported image"])
        }

        let targetSize = image.size.scaledToFit(maxEdge: maxSendImageEdge)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(targetSize.width), 1),
            pixelsHigh: max(Int(targetSize.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let representation = bitmap else {
            throw NSError(domain: "NPCImageSender", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not render PNG"])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "NPCImageSender", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
        }

        return data
    }

    private func postJSON(path: String, target: DisplayTarget, payload: [String: String], completion: @escaping (String) -> Void) {
        guard let url = URL(string: "http://\(target.host):\(target.port)\(path)") else {
            completion("Invalid target URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion("Send failed: \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion("No HTTP response")
                return
            }

            if (200..<300).contains(httpResponse.statusCode) {
                completion(path == "/clear" ? "Cleared display" : "Sent image")
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion("Server returned \(httpResponse.statusCode) \(body)")
            }
        }.resume()
    }

}

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ImageRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ImageRowView ?? ImageRowView()
        cell.identifier = identifier
        cell.configure(with: items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.fileURLs
        handleDroppedURLs(urls)
        return !urls.isEmpty
    }
}

extension MainWindowController: NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.fileURLs.isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.fileURLs
        handleDroppedURLs(urls)
        return !urls.isEmpty
    }
}

final class ImageRowView: NSTableCellView {
    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.backgroundColor = NSColor.black.cgColor

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumbnailView)
        addSubview(labels)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 72),
            thumbnailView.heightAnchor.constraint(equalToConstant: 72),

            labels.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with item: ImageItem) {
        thumbnailView.image = item.thumbnail
        nameLabel.stringValue = item.url.lastPathComponent
        detailLabel.stringValue = item.url.deletingLastPathComponent().path
    }
}

struct DisplayTarget: Equatable {
    let name: String
    let host: String
    let port: Int

    static func == (lhs: DisplayTarget, rhs: DisplayTarget) -> Bool {
        lhs.name == rhs.name && lhs.host == rhs.host && lhs.port == rhs.port
    }
}

final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var targetsByName: [String: DisplayTarget] = [:]
    var onUpdate: (([DisplayTarget]) -> Void)?

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        targetsByName.removeValue(forKey: service.name)
        notifyUpdate()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.ipv4Address else { return }
        targetsByName[sender.name] = DisplayTarget(name: sender.name, host: host, port: sender.port)
        notifyUpdate()
    }

    private func notifyUpdate() {
        let targets = Array(targetsByName.values)
        onUpdate?(targets)
    }
}

private extension NSPasteboard {
    var fileURLs: [URL] {
        readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

private extension NetService {
    var ipv4Address: String? {
        guard let addresses = addresses else { return nil }

        for data in addresses {
            var storage = sockaddr_storage()
            data.withUnsafeBytes { pointer in
                if let baseAddress = pointer.baseAddress {
                    memcpy(&storage, baseAddress, min(pointer.count, MemoryLayout<sockaddr_storage>.size))
                }
            }

            if Int32(storage.ss_family) == AF_INET {
                var address = sockaddr_in()
                withUnsafePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { reboundPointer in
                        address = reboundPointer.pointee
                    }
                }

                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sinAddress = address.sin_addr
                inet_ntop(AF_INET, &sinAddress, &buffer, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buffer)
            }
        }

        return nil
    }
}

private extension NSImage {
    func thumbnail(maxSize: NSSize) -> NSImage {
        let ratio = min(maxSize.width / size.width, maxSize.height / size.height)
        let thumbnailSize = NSSize(width: max(size.width * ratio, 1), height: max(size.height * ratio, 1))
        let image = NSImage(size: thumbnailSize)
        image.lockFocus()
        draw(in: NSRect(origin: .zero, size: thumbnailSize), from: .zero, operation: .copy, fraction: 1.0)
        image.unlockFocus()
        return image
    }
}

private extension NSSize {
    func scaledToFit(maxEdge: CGFloat) -> NSSize {
        guard width > 0, height > 0 else { return self }
        let currentMaxEdge = max(width, height)
        guard currentMaxEdge > maxEdge else { return self }
        let scale = maxEdge / currentMaxEdge
        return NSSize(width: width * scale, height: height * scale)
    }
}

private extension NSColor {
    var hexString: String {
        let color = usingColorSpace(.deviceRGB) ?? .black
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
