import Foundation

@main
struct PowerFlowTests {
    static func data(_ metrics: PowerMetrics, onAC: Bool = true, charging: Bool = false,
                     phase: PowerConnectionPhase = .onAC) -> PowerData {
        PowerData(
            systemPowerW: metrics.systemPowerW, batteryPowerW: metrics.batteryPowerW, acInputW: metrics.acInputW,
            acAdapterWattage: 0, batteryPercent: 0,
            isOnAC: onAC, isCharging: charging, fullyCharged: false,
            wallPowerW: nil, adapterEfficiencyLossW: nil,
            systemVoltageMV: nil, systemCurrentMA: nil,
            batteryVoltageMV: nil, batteryAmperageMA: nil,
            batteryTemperatureC: nil, cycleCount: nil,
            adapterDescription: nil, dataSource: .telemetry, timestamp: Date(),
            connectionPhase: phase,
            batteryHealthPercent: nil, designCapacityMAH: nil, rawMaxCapacityMAH: nil,
            nominalChargeCapacityMAH: nil, designCycleCount: nil,
            chargingVoltageMV: nil, chargingCurrentMA: nil,
            notChargingReason: nil, vacVoltageLimit: nil,
            cellVoltagesMV: nil, stateOfCharge: nil, qmaxMAH: nil,
            batteryCellLayout: nil, batteryParallelCellCurrents: nil,
            dailyMinSoc: nil, dailyMaxSoc: nil,
            chargeLimitPercent: 100, chargeLimitSource: .none,
            totalOperatingTimeMin: nil,
            lifetimeMaxTempC: nil, lifetimeMinTempC: nil, lifetimeAvgTempC: nil,
            lifetimeMaxPackVoltageMV: nil, lifetimeMinPackVoltageMV: nil,
            lifetimeMaxChargeCurrentMA: nil, lifetimeMaxDischargeCurrentMA: nil,
            batterySerial: nil, deviceName: nil,
            instantAmperageMA: nil, atCriticalLevel: nil,
            permanentFailureStatus: nil, batteryCellDisconnectCount: nil,
            avgTimeToEmptyMinutes: nil, avgTimeToFullMinutes: nil,
            remainingCapacityMAH: nil, fullChargeCapacityMAH: nil,
            averageSystemPowerW: nil, batteryManufactureDate: nil,
            smoothedDischargePowerW: nil, smoothedChargePowerW: nil,
            powerSources: metrics.sources
        )
    }

    static func resolve(_ input: Int?, _ load: Int?, _ battery: Any?,
                        instant: Int? = nil, average: Int? = nil,
                        onAC: Bool = true, charging: Bool = false,
                        inputVoltage: Int? = nil, inputCurrent: Int? = nil) -> PowerMetrics {
        var telemetry: [String: Any] = [:]
        if let input { telemetry["SystemPowerIn"] = input }
        if let load { telemetry["SystemLoad"] = load }
        if let battery { telemetry["BatteryPower"] = battery }
        if let inputVoltage { telemetry["SystemVoltageIn"] = inputVoltage }
        if let inputCurrent { telemetry["SystemCurrentIn"] = inputCurrent }
        return PowerMetrics.resolve(isOnAC: onAC, isCharging: charging, voltageMV: 12_000,
                                    amperageMA: average, instantAmperageMA: instant, telemetry: telemetry)
    }

    static func near(_ lhs: Double, _ rhs: Double) { precondition(abs(lhs - rhs) < 0.001, "\(lhs) != \(rhs)") }

    @MainActor static func main() async throws {
        // All reported fields win even when their independent I × V checks differ.
        let charge = resolve(70_000, 10_000, 60_000, instant: 4_000, charging: true,
                             inputVoltage: 20_000, inputCurrent: 4_000)
        near(charge.batteryPowerW, -60)
        near(charge.acInputW, 70)
        near(charge.systemPowerW, 10)
        precondition(charge.sources == PowerReadingSources(system: .systemLoad, battery: .batteryPower, adapter: .systemPowerIn))
        let charging = data(charge, charging: true)
        precondition(charging.isBatteryCharging && !charging.isSupplementalDischarge)
        near(charging.batteryChargeRateW, 60)
        near(charging.headerPowerW, 70)
        precondition(charging.withConnectionPhase(.onAC).withSmoothedPower(dischargeW: nil, chargeW: 60).powerSources == charge.sources)

        let zero = data(resolve(0, 0, 0, instant: -1_000, inputVoltage: 20_000, inputCurrent: 3_000))
        near(zero.systemPowerW, 0); near(zero.batteryPowerW, 0); near(zero.effectiveACOutputW, 0)
        precondition(zero.powerSources.adapter == .systemPowerIn && zero.powerSources.battery == .batteryPower)
        precondition(!zero.isSupplementalDischarge)

        let calculated = resolve(nil, 12_000, nil, instant: 500, inputVoltage: 20_000, inputCurrent: 1_000)
        near(calculated.batteryPowerW, -6); near(calculated.acInputW, 20)
        precondition(calculated.sources.battery == .instantCurrent && calculated.sources.adapter == .adapterCurrent)
        let average = resolve(20_000, 12_000, nil, average: 500)
        near(average.batteryPowerW, -6); precondition(average.sources.battery == .averageCurrent)
        let computedZero = resolve(nil, 12_000, nil, instant: 0, average: -1_000, inputVoltage: 20_000, inputCurrent: 0)
        near(computedZero.batteryPowerW, 0); near(computedZero.acInputW, 0)

        let estimatedSystem = resolve(70_000, nil, 60_000, inputVoltage: 20_000, inputCurrent: 4_000)
        near(estimatedSystem.systemPowerW, 10) // Adapter I × V must NOT become system load.
        precondition(estimatedSystem.sources.system == .powerBalance)
        let estimatedInput = data(resolve(nil, 12_000, 6_000), charging: true)
        near(estimatedInput.effectiveACOutputW, 18)
        precondition(estimatedInput.effectiveACOutputSource == .powerBalance)
        let estimatedBattery = data(resolve(12_100, 13_100, nil))
        near(estimatedBattery.batteryPowerW, 1)
        precondition(estimatedBattery.powerSources.battery == .powerBalance)
        let realSmallSupplement = data(resolve(12_100, 13_100, -1_000))
        precondition(realSmallSupplement.isSupplementalDischarge)
        near(realSmallSupplement.batterySupplementalW, 1)
        let realHighLoad = data(resolve(60_000, 80_000, -20_000))
        precondition(realHighLoad.isSupplementalDischarge)
        near(realHighLoad.systemPowerW, 80)

        // No circular estimates or replacement of missing measurements by "measured zero".
        let onlyInput = resolve(20_000, nil, nil)
        precondition(!onlyInput.sources.system.hasValue && !onlyInput.sources.battery.hasValue)
        let onlySystem = data(resolve(nil, 20_000, nil))
        precondition(!onlySystem.powerSources.adapter.hasValue && !onlySystem.powerSources.battery.hasValue)
        precondition(onlySystem.acOutputPowerText == "—" && onlySystem.batteryDischargePowerText == "—")
        let impossibleInput = resolve(nil, 10_000, -20_000)
        precondition(!impossibleInput.sources.adapter.hasValue)

        let wrapped = UInt64(bitPattern: Int64(-6_000))
        let batteryOnly = data(resolve(140_000, 10_000, wrapped, instant: -1_000, onAC: false), onAC: false, phase: .onBattery)
        near(batteryOnly.batteryProvidesW, 6)
        near(batteryOnly.systemPowerW, 10) // Preserve independent readings, not forced equality.
        near(batteryOnly.effectiveACOutputW, 0)
        precondition(batteryOnly.batteryDischargePowerText == "6.0 W")
        var estimator = BatteryTimeEstimator()
        near(estimator.smoothedPower(for: batteryOnly).dischargeW!, 6)
        let batteryFallback = resolve(nil, 10_000, nil, onAC: false)
        near(batteryFallback.batteryPowerW, 10)
        precondition(batteryFallback.sources.battery == .powerBalance)
        let legacy = PowerMetrics.resolve(isOnAC: false, isCharging: false, voltageMV: 12_000,
                                          amperageMA: -1_000, instantAmperageMA: nil, telemetry: nil)
        near(legacy.systemPowerW, 12); near(legacy.batteryPowerW, 12)
        precondition(legacy.sources.battery == .averageCurrent && legacy.sources.system == .batteryEstimate)

        let staleCharge = data(resolve(70_000, 12_000, 60_000, instant: 5_000, onAC: false), onAC: false, phase: .onBattery)
        precondition(staleCharge.powerSources.battery == .transition)
        precondition(staleCharge.batteryDischargePowerText == "—")
        let coherentFallback = resolve(20_000, 12_000, -8_000, instant: 500, charging: true)
        near(coherentFallback.batteryPowerW, -6)
        precondition(coherentFallback.sources.battery == .instantCurrent)
        let conflict = data(resolve(20_000, 12_000, -8_000, instant: -1_000, charging: true), charging: true)
        precondition(conflict.powerSources.battery == .transition && !conflict.isSupplementalDischarge)
        let conflictingEstimate = resolve(20_000, 72_000, nil, charging: true)
        precondition(conflictingEstimate.sources.battery == .transition)
        // Regression: a real charging snapshot had a contradictory telemetry
        // BatteryPower, and SystemLoad equalled input minus that rejected value.
        func capturedCharge(_ alternate: Any?) -> PowerMetrics {
            PowerMetrics.resolve(isOnAC: true, isCharging: true, voltageMV: 12_700,
                amperageMA: 3_809, instantAmperageMA: 3_809,
                telemetry: ["SystemPowerIn": 75_338, "SystemLoad": 92_500, "BatteryPower": -17_162],
                batteryData: alternate.map { ["SystemPower": $0] })
        }
        let corrected = capturedCharge(29.67804718017578)
        near(corrected.systemPowerW, 29.67804718017578)
        near(corrected.batteryPowerW, -48.3743)
        near(corrected.acInputW, 75.338)
        precondition(corrected.sources.system == .batteryDataSystemPower)
        precondition(corrected.sources.battery == .instantCurrent)
        precondition(data(corrected, charging: true).isBatteryCharging)
        precondition(!data(corrected, charging: true).isSupplementalDischarge)
        // Prefer BatteryData.SystemPower even when SystemLoad is also valid.
        let preferred = PowerMetrics.resolve(isOnAC: true, isCharging: true, voltageMV: 12_000,
            amperageMA: 1_000, instantAmperageMA: 1_000,
            telemetry: ["SystemPowerIn": 30_000, "SystemLoad": 18_000, "BatteryPower": 12_000],
            batteryData: ["SystemPower": 17.5])
        near(preferred.systemPowerW, 17.5)
        precondition(preferred.sources.system == .batteryDataSystemPower)
        // Missing, unsupported, non-finite, negative, or inconsistent primary
        // readings must fall through to a valid SystemLoad, not straight to balance.
        for invalidPrimary in [nil, 17_500, Double.nan, Double.infinity, -1.0, 40.5] as [Any?] {
            let fallback = PowerMetrics.resolve(isOnAC: true, isCharging: true, voltageMV: 12_000,
                amperageMA: 1_000, instantAmperageMA: 1_000,
                telemetry: ["SystemPowerIn": 30_000, "SystemLoad": 18_000, "BatteryPower": 12_000],
                batteryData: invalidPrimary.map { ["SystemPower": $0] })
            near(fallback.systemPowerW, 18)
            precondition(fallback.sources.system == .systemLoad)
        }
        let primaryZero = PowerMetrics.resolve(isOnAC: true, isCharging: false, voltageMV: nil,
            amperageMA: nil, instantAmperageMA: nil,
            telemetry: ["SystemLoad": 12_000], batteryData: ["SystemPower": NSNumber(value: 0.0)])
        near(primaryZero.systemPowerW, 0)
        precondition(primaryZero.sources.system == .batteryDataSystemPower, "A valid primary zero must win")
        for unavailable in [nil, 29_678, Double.nan, Double.infinity, -1.0, 92.5] as [Any?] {
            let estimate = capturedCharge(unavailable)
            near(estimate.systemPowerW, 26.9637)
            precondition(estimate.sources.system == .powerBalance)
        }
        let noPlausibleLoad = resolve(20_000, 80_000, -8_000, instant: 4_000, charging: true)
        precondition(!noPlausibleLoad.sources.system.hasValue, "Negative system estimates must not be fabricated")
        let idleFallback = PowerMetrics.resolve(isOnAC: true, isCharging: false, voltageMV: nil,
            amperageMA: nil, instantAmperageMA: nil, telemetry: ["SystemPowerIn": 0],
            batteryData: ["SystemPower": NSNumber(value: 0.0)])
        near(idleFallback.systemPowerW, 0)
        let connecting = data(resolve(60_000, 80_000, -20_000), phase: .connectingAC)
        precondition(!connecting.isSupplementalDischarge && !connecting.isBatteryCharging)

        let suite = "PowerTop.RefreshTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = PowerMonitor(defaults: defaults)
        for _ in 0..<3 {
            let count = monitor.uiRefreshToken
            let start = Date()
            monitor.refreshNow()
            precondition(monitor.uiRefreshToken == count + 1)
            if monitor.isDataAvailable { precondition(monitor.currentData.timestamp >= start) }
        }
        print("PASS: SystemPower > SystemLoad > balance, primary zero and invalid-primary fallback, contradictory charging regression, direct system watts, invalid alternative encodings, reported > component I × V > independent balance; valid zeros, missing inputs, no circular estimates, transitions, real battery output, and refresh re-reads")
        if CommandLine.arguments.contains("--read-system"), let raw = getIOServiceProperties(className: "AppleSmartBattery") {
            let onAC = extractBool(from: raw, key: "ExternalConnected") ?? false
            let flag = extractBool(from: raw, key: "IsCharging") ?? false
            let metrics = PowerMetrics.resolve(isOnAC: onAC, isCharging: flag,
                voltageMV: extractInt(from: raw, key: "Voltage"), amperageMA: extractInt(from: raw, key: "Amperage"),
                instantAmperageMA: extractInt(from: raw, key: "InstantAmperage"), telemetry: extractDict(from: raw, key: "PowerTelemetryData"),
                batteryData: extractDict(from: raw, key: "BatteryData"))
            let display = data(metrics, onAC: onAC, charging: flag, phase: onAC ? .onAC : .onBattery)
            if let telemetry = extractDict(from: raw, key: "PowerTelemetryData") {
                let reported = extractInt(from: telemetry, key: "BatteryPower").map { Double($0) / 1000 }
                let current = extractInt(from: raw, key: "InstantAmperage") ?? extractInt(from: raw, key: "Amperage")
                let voltage = extractInt(from: raw, key: "Voltage")
                let calculated = current.flatMap { a in voltage.map { Double(a) * Double($0) / 1_000_000 } }
                print("BATTERY candidates (positive = charging): reported=\(String(describing: reported)) W, I×V=\(String(describing: calculated)) W")
            }
            print("LIVE: onAC=\(onAC), system=\(metrics.systemPowerW)W, adapter=\(metrics.acInputW)W, battery output=\(metrics.batteryPowerW)W, charging=\(display.isBatteryCharging), supplement=\(display.isSupplementalDischarge)")
        }
    }
}
