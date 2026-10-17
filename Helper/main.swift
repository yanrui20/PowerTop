import Foundation

// launchd supplies the approved client hash and the installing user's UID from its root-owned plist.
let arguments = CommandLine.arguments
if arguments.count == 2 && arguments[1] == "--self-test" {
    let helper = EnergyHelper(clientHash: String(repeating: "a", count: 40), ownerUID: getuid())
    helper.setMode(9, source: "AC Power") { precondition($0 != nil) }
    helper.setMode(0, source: "-a; touch /tmp/invalid") { precondition($0 != nil) }
    helper.ping { precondition($0 == "1") }
    print("PASS: helper rejects invalid modes and sources; no command executed")
    exit(0)
}
guard geteuid() == 0, arguments.count == 3,
      arguments[1].count == 40, arguments[1].allSatisfy({ $0.isHexDigit }),
      let uid = UInt32(arguments[2]), uid > 0 else { exit(64) }
let helper = EnergyHelper(clientHash: arguments[1], ownerUID: uid)
let listener = NSXPCListener(machServiceName: EnergyHelperConstants.service)
listener.delegate = helper
listener.resume()
RunLoop.current.run()
