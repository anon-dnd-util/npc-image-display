import UIKit
import Darwin

final class MainViewController: UIViewController {
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private var currentBackgroundColor = UIColor.black
    private var server: HTTPImageServer?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        startServer()
    }

    private func configureView() {
        applyBackgroundColor(.black)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.text = "NPC Image Display"
        view.addSubview(titleLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .regular)
        statusLabel.textColor = UIColor(white: 0.85, alpha: 1.0)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Starting server..."
        view.addSubview(statusLabel)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        hintLabel.textColor = UIColor(white: 0.65, alpha: 1.0)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.text = "Keep this app open while sending images from your Mac."
        view.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -50),

            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),

            hintLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            hintLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
        ])
    }

    private func startServer() {
        do {
            let server = try HTTPImageServer(port: 8080, serviceName: Self.displayServiceName())
            self.server = server

            server.onImage = { [weak self] imageData, _, backgroundColor in
                guard let self = self else { return false }
                guard let image = UIImage(data: imageData) else { return false }
                if let color = backgroundColor {
                    self.applyBackgroundColor(UIColor(displayColor: color) ?? self.currentBackgroundColor)
                }
                self.imageView.image = image
                self.titleLabel.isHidden = true
                self.statusLabel.isHidden = true
                self.hintLabel.isHidden = true
                return true
            }

            server.onClear = { [weak self] backgroundColor in
                guard let self = self else { return }
                if let color = backgroundColor {
                    self.applyBackgroundColor(UIColor(displayColor: color) ?? self.currentBackgroundColor)
                }
                self.imageView.image = nil
                self.titleLabel.text = "NPC Image Display"
                self.titleLabel.isHidden = false
                self.statusLabel.isHidden = false
                self.hintLabel.isHidden = false
            }

            server.onStateChange = { [weak self] message in
                self?.statusLabel.text = message
            }

            server.start()
            statusLabel.text = "\(Self.displayServiceName())\nListening at:\nhttp://\(Self.localIPAddress() ?? "IPAD_IP"):8080"
        } catch {
            statusLabel.text = "Server failed to start:\n\(error.localizedDescription)"
        }
    }

    private func applyBackgroundColor(_ color: UIColor) {
        currentBackgroundColor = color
        view.backgroundColor = color
        imageView.backgroundColor = color

        let textColor = color.prefersDarkText ? UIColor.black : UIColor.white
        let secondaryTextColor = textColor.withAlphaComponent(0.72)
        titleLabel.textColor = textColor
        statusLabel.textColor = secondaryTextColor
        hintLabel.textColor = secondaryTextColor
    }

    private static func localIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }

        var pointer = interfaces
        while pointer != nil {
            guard let interface = pointer?.pointee else {
                pointer = pointer?.pointee.ifa_next
                continue
            }

            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    break
                }
            }

            pointer = pointer?.pointee.ifa_next
        }

        return address
    }

    private static func displayServiceName() -> String {
        let deviceName = UIDevice.current.name
        let modelName = hardwareModelName()
        return "\(modelName) - \(deviceName)"
    }

    private static func hardwareModelName() -> String {
        let identifier = hardwareIdentifier()
        let names: [String: String] = [
            "iPad4,1": "iPad Air 1",
            "iPad4,2": "iPad Air 1",
            "iPad4,3": "iPad Air 1",
            "iPad5,3": "iPad Air 2",
            "iPad5,4": "iPad Air 2",
            "iPad11,3": "iPad Air 3",
            "iPad11,4": "iPad Air 3",
            "iPad13,1": "iPad Air 4",
            "iPad13,2": "iPad Air 4",
            "iPad13,16": "iPad Air 5",
            "iPad13,17": "iPad Air 5",
            "iPad14,8": "iPad Air 11-inch M2",
            "iPad14,9": "iPad Air 11-inch M2",
            "iPad14,10": "iPad Air 13-inch M2",
            "iPad14,11": "iPad Air 13-inch M2",
        ]

        if let name = names[identifier] {
            return name
        }

        if identifier.hasPrefix("iPad") {
            return "iPad \(identifier)"
        }

        if identifier.hasPrefix("iPhone") {
            return "iPhone \(identifier)"
        }

        return identifier
    }

    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }

        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}

private extension UIColor {
    convenience init?(displayColor value: String) {
        let namedColors: [String: String] = [
            "black": "#000000",
            "white": "#ffffff",
            "gray": "#808080",
            "grey": "#808080",
            "red": "#ff0000",
            "green": "#00ff00",
            "blue": "#0000ff",
        ]

        let normalized = namedColors[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? value
        var hex = normalized.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        if hex.count == 3 {
            hex = hex.map { String(repeating: String($0), count: 2) }.joined()
        }

        guard hex.count == 6, let number = UInt32(hex, radix: 16) else {
            return nil
        }

        let red = CGFloat((number >> 16) & 0xff) / 255.0
        let green = CGFloat((number >> 8) & 0xff) / 255.0
        let blue = CGFloat(number & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }

    var prefersDarkText: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return false
        }

        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.62
    }
}
