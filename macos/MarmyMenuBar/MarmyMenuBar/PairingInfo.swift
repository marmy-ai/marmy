import Foundation

struct PairingInfo {
    let hostname: String
    let localIP: String
    let port: UInt16
    let token: String
    let tailscaleIP: String?
    let geminiApiKey: String?

    var address: String {
        "\(localIP):\(port)"
    }

    var tailscaleAddress: String? {
        tailscaleIP.map { "\($0):\(port)" }
    }

    var displayText: String {
        var text = """
        Host: \(hostname)
        LAN: \(address)
        """
        if let tsAddr = tailscaleAddress {
            text += "\nTailscale: \(tsAddr)"
        }
        text += "\nToken: \(token)"
        return text
    }

    var clipboardText: String {
        var text = "LAN: \(address)"
        if let tsAddr = tailscaleAddress {
            text += "\nTailscale: \(tsAddr)"
        }
        text += "\nToken: \(token)"
        return text
    }
}
