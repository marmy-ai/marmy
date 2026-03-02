import Foundation

struct PairingInfo {
    let hostname: String
    let localIP: String
    let port: UInt16
    let token: String

    var address: String {
        "\(localIP):\(port)"
    }

    var displayText: String {
        """
        Host: \(hostname)
        Address: \(address)
        Token: \(token)
        """
    }

    var clipboardText: String {
        "Address: \(address)\nToken: \(token)"
    }
}
