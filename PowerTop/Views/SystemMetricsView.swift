import SwiftUI

struct SystemMetricsView: View {
    let metrics: SystemMetricsSnapshot
    var memoryAccounting: MemoryAccounting = .cacheAdjusted

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "System Resources"))
                .font(.system(size: 12, weight: .semibold))
            PowerRowView(icon: "cpu", iconColor: .blue, label: "CPU",
                         value: SystemMetricsSnapshot.percentText(metrics.cpuPercent))
                .help(String(localized: "CPU usage across all cores, averaged since the previous reading."))
            PowerRowView(icon: "square.stack.3d.up", iconColor: .purple, label: "GPU",
                         value: SystemMetricsSnapshot.percentText(metrics.gpuPercent))
                .help(String(localized: "GPU usage reported by the driver. With multiple GPUs, the busiest is shown."))
            VStack(alignment: .leading, spacing: 2) {
                PowerRowView(icon: "memorychip", iconColor: .orange, label: String(localized: "Memory Usage"),
                             value: SystemMetricsSnapshot.percentText(metrics.memory?.percent(for: memoryAccounting)))
                Text(metrics.memoryText(using: memoryAccounting))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .help(memoryAccounting.explanation)
            PowerRowView(icon: "thermometer.medium", iconColor: .orange, label: String(localized: "CPU Temperature"),
                         value: metrics.hardware.cpuTemperature.map { String(format: "%.1f °C", $0.averageCelsius) } ?? "—")
                .help(String(localized: "Average of the identified CPU temperature sensors. Unavailable sensors are not estimated."))
            if let fans = metrics.hardware.fans {
                if fans.isEmpty {
                    PowerRowView(icon: "fan", iconColor: .cyan, label: String(localized: "Fans"), value: String(localized: "No fans"))
                } else {
                    ForEach(fans, id: \.index) { fan in
                        PowerRowView(icon: "fan", iconColor: .cyan, label: String(format: String(localized: "Fan %d"), fan.index + 1),
                                     value: fan.rpm.map { String(format: "%.0f RPM", $0) } ?? "—")
                    }
                }
            } else {
                PowerRowView(icon: "fan", iconColor: .cyan, label: String(localized: "Fans"), value: "—")
            }
            VStack(alignment: .leading, spacing: 2) {
                PowerRowView(icon: "internaldrive", iconColor: .purple, label: String(localized: "Startup Disk"),
                             value: SystemMetricsSnapshot.percentText(metrics.disk?.usedPercent))
                Text(metrics.disk?.capacityText ?? "—")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .help(String(localized: "Available space includes reclaimable storage when macOS reports it. Used percentage is total minus available."))
            PowerRowView(icon: "arrow.down", iconColor: .green, label: String(localized: "Download"),
                         value: SystemMetricsSnapshot.rateText(metrics.downloadBytesPerSecond))
            PowerRowView(icon: "arrow.up", iconColor: .blue, label: String(localized: "Upload"),
                         value: SystemMetricsSnapshot.rateText(metrics.uploadBytesPerSecond))

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
