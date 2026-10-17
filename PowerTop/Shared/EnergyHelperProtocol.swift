import Foundation

@objc(PowerTopEnergyHelperProtocol) protocol EnergyHelperProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func setMode(_ mode: Int, source: String, withReply reply: @escaping (String?) -> Void)
}

enum EnergyHelperConstants {
    static let service = "com.kdolphin.PowerTop.EnergyHelper"
    static let version = "1"
    static let executable = "/Library/PrivilegedHelperTools/" + service
    static let plist = "/Library/LaunchDaemons/" + service + ".plist"
}
