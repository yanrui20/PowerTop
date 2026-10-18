import SwiftUI

/// Shared authorization for sampling and energy modes, shown with app settings.
struct AdministratorAuthorizationView: View {
    let controller: EnergyModeController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Authorize once for manual and scheduled sampling and power-mode switching."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Authorize or Repair Access")) {
                        Task { await controller.configureAdministratorAuthorization(enabled: true) }
                    }
                    if controller.isAdministratorAuthorized || controller.helperInstalled {
                        Button(String(localized: "Remove Authorization")) {
                            Task { await controller.configureAdministratorAuthorization(enabled: false) }
                        }
                    }
                }
                .disabled(controller.isBusy)
                .buttonStyle(.borderless)
            } label: {
                HStack(spacing: 6) {
                    Text(String(localized: "Administrator Authorization"))
                    Spacer(minLength: 0)
                    if controller.isAuthorizing {
                        ProgressView().controlSize(.small)
                    } else if controller.isAdministratorAuthorized {
                        Text(String(localized: "Authorized"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = controller.authorizationError {
                Text(message).font(.system(size: 10)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
