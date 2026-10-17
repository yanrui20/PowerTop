import SwiftUI

struct PopoverView: View {
    static let preferredWidth: CGFloat = 280

    let monitor: PowerMonitor
    var openDetails: (() -> Void)? = nil

    @State private var refreshIntervalText = ""
    @State private var refreshIntervalError = false
    @State private var isManuallyRefreshing = false

    private var data: PowerData { monitor.currentData }

    var body: some View {
        ScrollView {
            contentSections
        }
        .frame(width: Self.preferredWidth, height: min(760, (NSScreen.main?.visibleFrame.height ?? 850) - 60))
            .onAppear {
                DispatchQueue.main.async {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
    }

    // The actual stacked sections (no extra frame/fixed/background here).
    private var contentSections: some View {
        VStack(spacing: 0) {
            if !monitor.isDataAvailable {
                unavailableBanner
            }
            headerSection
            Divider().padding(.horizontal, 12)
            powerFlowDiagram
                .padding(.vertical, 8)
            Divider().padding(.horizontal, 12)
            metricsSection
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider().padding(.horizontal, 12)
            batterySection
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider().padding(.horizontal, 12)
            energyModeSection
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider().padding(.horizontal, 12)
            significantEnergySection
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider().padding(.horizontal, 12)
            footerSection
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(String(localized: "Built-in battery not detected. PowerTop requires a MacBook."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
    }

    private var headerIconColor: Color {
        if data.isConnectingAC { return .secondary }
        return data.effectiveIsOnAC ? .green : .orange
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: data.effectiveIsOnAC ? "powerplug.fill" : "battery.50")
                .foregroundStyle(headerIconColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.powerSourceDescription)
                    .font(.system(size: 13, weight: .semibold))
                Text(String(format: "%.1f W", data.headerPowerW))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            Spacer()
            Button {
                Task {
                    isManuallyRefreshing = true
                    monitor.refreshNow()
                    await monitor.energyModes.refresh()
                    await monitor.significantEnergyApps.refresh()
                    isManuallyRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(isManuallyRefreshing)
            .help(String(localized: "Refresh Now"))
            .accessibilityLabel(String(localized: "Refresh Now"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Power Flow Diagram

    @ViewBuilder
    private var powerFlowDiagram: some View {
        Group {
            if data.isConnectingAC {
                connectingACDiagram
            } else if data.isSupplementalDischarge {
                supplementalDischargeDiagram
            } else if data.effectiveIsOnAC {
                acPoweredDiagram
            } else {
                batteryPoweredDiagram
            }
        }
        .padding(.horizontal, 14)
    }

    private var connectingACDiagram: some View {
        VStack(spacing: 6) {
            sourceBox(
                title: String(localized: "AC Connecting"),
                value: "—",
                color: .secondary,
                icon: "powerplug.fill"
            )
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            destBox(
                title: String(localized: "System"),
                value: String(format: "%.1f W", data.systemPowerW),
                color: .primary,
                icon: "desktopcomputer"
            )
        }
    }

    private var acPoweredDiagram: some View {
        VStack(spacing: 6) {
            sourceBox(
                title: String(localized: "AC Powered"),
                value: String(format: "%.1f W", data.effectiveACOutputW),
                color: .green,
                icon: "powerplug.fill"
            )
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)

            if data.isBatteryCharging {
                HStack(spacing: 10) {
                    destBox(
                        title: String(localized: "Battery Charging"),
                        value: String(format: "%.1f W", data.batteryChargeRateW),
                        color: .blue,
                        icon: "battery.100.bolt"
                    )
                    destBox(
                        title: String(localized: "System"),
                        value: String(format: "%.1f W", data.systemPowerW),
                        color: .primary,
                        icon: "desktopcomputer"
                    )
                }
            } else {
                destBox(
                    title: String(localized: "System"),
                    value: String(format: "%.1f W", data.systemPowerW),
                    color: .primary,
                    icon: "desktopcomputer"
                )
            }
        }
    }

    private var supplementalDischargeDiagram: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                sourceBox(
                    title: String(localized: "AC Powered"),
                    value: String(format: "%.1f W", data.effectiveACOutputW),
                    color: .green,
                    icon: "powerplug.fill"
                )
                sourceBox(
                    title: String(localized: "Battery Discharge"),
                    value: String(format: "%.1f W", data.batterySupplementalW),
                    color: .orange,
                    icon: "battery.50"
                )
            }

            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)

            destBox(
                title: String(localized: "System"),
                value: String(format: "%.1f W", data.systemPowerW),
                color: .primary,
                icon: "desktopcomputer"
            )
        }
    }

    private var batteryPoweredDiagram: some View {
        VStack(spacing: 6) {
            sourceBox(
                title: String(localized: "Battery Discharge"),
                value: String(format: "%.1f W", data.systemPowerW),
                color: .orange,
                icon: "battery.50"
            )
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            destBox(
                title: String(localized: "System"),
                value: String(format: "%.1f W", data.systemPowerW),
                color: .primary,
                icon: "desktopcomputer"
            )
        }
    }

    private func sourceBox(title: String, value: String, color: Color, icon: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func destBox(title: String, value: String, color: Color, icon: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        VStack(spacing: 6) {
            PowerRowView(icon: "desktopcomputer", iconColor: .primary, label: String(localized: "System Power"), value: String(format: "%.1f W", data.systemPowerW))

            if data.effectiveIsOnAC && !data.isConnectingAC {
                PowerRowView(icon: "powerplug.fill", iconColor: .green, label: String(localized: "AC Adapter Output"), value: String(format: "%.1f W", data.effectiveACOutputW))
            }

            if data.isBatteryCharging {
                PowerRowView(
                    icon: "arrow.down.to.line",
                    iconColor: .blue,
                    label: String(localized: "Battery Charging"),
                    value: String(format: "%.1f W", data.batteryChargeRateW)
                )
            } else if data.isSupplementalDischarge {
                PowerRowView(
                    icon: "arrow.up.right.and.arrow.down.left",
                    iconColor: .orange,
                    label: String(localized: "Battery Supplement"),
                    value: String(format: "%.1f W", data.batterySupplementalW)
                )
            }

            if data.effectiveIsOnAC && data.acAdapterWattage > 0 {
                PowerRowView(
                    icon: "bolt.fill",
                    iconColor: .green,
                    label: String(localized: "Charger Spec"),
                    value: "\(data.acAdapterWattage) W" + (data.adapterDescription.map { " (\($0))" } ?? ""),
                    wrapsValue: data.adapterDescription != nil
                )
            }

            if data.dataSource == .legacy {
                PowerRowView(
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .yellow,
                    label: String(localized: "Data Source"),
                    value: String(localized: "Estimation Mode"),
                    wrapsValue: true
                )
            }
        }
    }

    // MARK: - Battery

    private var batterySection: some View {
        VStack(spacing: 6) {
            let levelTint: Color = data.batteryPercent <= 20
                ? .red
                : (data.batteryPercent <= 50 ? .orange : .green)
            PopoverMetricBarRow(
                icon: "battery.100",
                iconColor: levelTint,
                label: String(localized: "Battery Level"),
                progress: Double(data.batteryPercent),
                valueText: "\(data.batteryPercent)%",
                barTint: levelTint
            )

            if let timeText = data.estimatedTimeRemainingText {
                PowerRowView(
                    icon: "clock",
                    iconColor: data.isBatteryCharging ? .blue : .orange,
                    label: data.estimatedTimeRemainingLabel,
                    value: timeText
                )
            }

            if let health = data.batteryHealthPercent {
                let healthTint: Color = health >= 80 ? .green : (health >= 60 ? .orange : .red)
                PopoverMetricBarRow(
                    icon: "heart.fill",
                    iconColor: healthTint,
                    label: String(localized: "Health"),
                    progress: Double(health),
                    valueText: "\(health)%",
                    barTint: healthTint,
                    valueColor: healthTint
                )
            }

            if let temp = data.batteryTemperatureC {
                PowerRowView(icon: "thermometer.medium", iconColor: temp > 40 ? .red : .secondary, label: String(localized: "Battery Temp"), value: String(format: "%.1f °C", temp))
            }
            if let cycles = data.cycleCount {
                PowerRowView(icon: "arrow.triangle.2.circlepath", iconColor: .secondary, label: String(localized: "Cycle Count"), value: "\(cycles)" + (data.designCycleCount.map { "/\($0)" } ?? ""))
            }
            if let voltage = data.batteryVoltageMV {
                PowerRowView(icon: "waveform.path", iconColor: .secondary, label: String(localized: "Battery Voltage"), value: String(format: "%.2f V", Double(voltage) / 1000.0))
            }
            if let reason = data.notChargingReasonDescription,
               data.effectiveIsOnAC && !data.isConnectingAC && !data.isBatteryCharging {
                PowerRowView(
                    icon: "info.circle",
                    iconColor: .blue,
                    label: String(localized: "Not Charging Reason"),
                    value: reason,
                    wrapsValue: true
                )
            }
        }
    }

    private var energyModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Energy Mode")).font(.system(size: 12, weight: .semibold))
                Spacer()
                if monitor.energyModes.isChanging { ProgressView().controlSize(.small) }
            }
            ForEach(EnergyPowerSource.allCases, id: \.self) { source in
                if let setting = monitor.energyModes.settings[source] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(EnergyMode.allCases, id: \.self) { mode in
                                Button {
                                    Task { await monitor.energyModes.select(mode, source: source) }
                                } label: {
                                    Text(mode.title)
                                        .font(.system(size: 11))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(setting.mode == mode ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04),
                                                    in: RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .disabled(monitor.energyModes.isChanging || monitor.energyModes.isRefreshing
                                          || (mode == .high && !setting.supportsHighPower))
                                .accessibilityAddTraits(setting.mode == mode ? .isSelected : [])
                                .help(mode == .high && !setting.supportsHighPower
                                      ? String(localized: "High Power Mode is not available for this power source.") : mode.title)
                            }
                        }
                    }
                }
            }
            if monitor.energyModes.settings.isEmpty {
                Text(String(localized: "Unable to read energy modes."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let message = monitor.energyModes.errorMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if monitor.energyModes.quickSwitchEnabled {
                Text(String(localized: "Quick switching enabled"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            DisclosureGroup(String(localized: "Quick Switching")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Authorize once to switch without a password. The helper can only change energy modes."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Enable or Repair Quick Switching")) {
                        Task { await monitor.energyModes.configureQuickSwitch(enabled: true) }
                    }
                    if monitor.energyModes.quickSwitchEnabled || monitor.energyModes.helperInstalled {
                        Button(String(localized: "Remove Quick Switching")) {
                            Task { await monitor.energyModes.configureQuickSwitch(enabled: false) }
                        }
                    }
                }
                .disabled(monitor.energyModes.isChanging || monitor.energyModes.isRefreshing)
                .buttonStyle(.borderless)
            }
            .font(.system(size: 11))
        }
        .task(id: monitor.isPopoverVisible) {
            guard monitor.isPopoverVisible else { return }
            await monitor.energyModes.refresh()
            while !Task.isCancelled {
                await monitor.significantEnergyApps.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    private var significantEnergySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Using Significant Energy"))
                .font(.system(size: 12, weight: .semibold))
            if !monitor.significantEnergyApps.hasLoaded {
                Text(String(localized: "Reading energy usage…"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !monitor.significantEnergyApps.isAvailable {
                Text(String(localized: "System energy usage is currently unavailable."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if monitor.significantEnergyApps.apps.isEmpty {
                Text(String(localized: "No Apps Using Significant Energy"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.significantEnergyApps.apps) { app in
                    Button { monitor.significantEnergyApps.openActivityMonitor() } label: {
                        HStack(spacing: 6) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                            Text(app.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(String(localized: "Open Activity Monitor")) {
                monitor.significantEnergyApps.openActivityMonitor()
            }
            .font(.system(size: 10)).buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 6) {
            Button {
                openDetailWindow()
            } label: {
                HStack {
                    Image(systemName: "chart.bar.doc.horizontal")
                    Text(String(localized: "Details"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(String(localized: "Read Every"))
                    TextField("2", text: $refreshIntervalText)
                        .textFieldStyle(.roundedBorder).frame(width: 45)
                        .onSubmit { applyRefreshInterval() }
                    Text(String(localized: "Seconds"))
                    Spacer()
                    Button(String(localized: "Apply")) { applyRefreshInterval() }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 11))
                .onAppear { refreshIntervalText = monitor.updateInterval.formatted(.number.grouping(.never)) }
                if refreshIntervalError {
                    Text(String(localized: "Enter an interval from 1 to 300 seconds."))
                        .font(.system(size: 10)).foregroundStyle(.red)
                }
                Toggle(String(localized: "Launch at Login"), isOn: Binding(
                    get: { monitor.launchAtLogin },
                    set: { monitor.launchAtLogin = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

                if let error = monitor.launchAtLoginError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(String(localized: "Show Battery in Menu Bar"), isOn: Binding(
                    get: { monitor.showBatteryInMenuBar },
                    set: { monitor.showBatteryInMenuBar = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

                Toggle(String(localized: "Show Power in Menu Bar"), isOn: Binding(
                    get: { monitor.showPowerInMenuBar },
                    set: { monitor.showPowerInMenuBar = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()

                Text(AppInfo.versionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                Button(String(localized: "Quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func applyRefreshInterval() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        guard let value = formatter.number(from: refreshIntervalText)?.doubleValue,
              value.isFinite, PowerMonitor.refreshIntervalRange.contains(value) else {
            refreshIntervalError = true
            return
        }
        monitor.updateInterval = value
        refreshIntervalError = false
        monitor.refreshNow()
    }

    private func openDetailWindow() {
        if let openDetails {
            openDetails()
            return
        }
        let detailTitle = String(localized: "PowerTop Details")
        if let window = NSApp.windows.first(where: { $0.title == detailTitle }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Popover metric bar row

/// Icon + fixed label + flexible bar + trailing value — bar starts align in EN/ZH.
/// Font matches `PowerRowView` (12pt system, no scale-down, no rounded digits).
private struct PopoverMetricBarRow: View {
    /// Fits English "Battery Level" at full 12pt without shrinking the label.
    static let labelWidth: CGFloat = 96
    static let valueMinWidth: CGFloat = 40

    let icon: String
    let iconColor: Color
    let label: String
    let progress: Double
    var total: Double = 100
    let valueText: String
    let barTint: Color
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: PowerRowView.iconWidth)

            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
                .lineLimit(1)

            ProgressView(value: min(max(progress, 0), total), total: max(total, 1))
                .progressViewStyle(.linear)
                .tint(barTint)

            Text(valueText)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .frame(minWidth: Self.valueMinWidth, alignment: .trailing)
        }
        .font(.system(size: 12))
    }
}