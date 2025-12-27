import SwiftUI

struct SetupWizardView: View {
    @EnvironmentObject private var model: PhotoBackupViewModel
    @State private var currentStep: Int = 1
    private let totalSteps = 2

    var body: some View {
        ZStack {
            DashboardBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with step indicator and skip button
                header
                    .padding(.top, 20)
                    .padding(.horizontal, 28)

                Spacer()

                // Main content area
                Group {
                    switch currentStep {
                    case 1:
                        photosPermissionStep
                    case 2:
                        immichConfigStep
                    default:
                        EmptyView()
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
                .animation(.easeInOut(duration: 0.3), value: currentStep)

                Spacer()

                // Navigation buttons
                navigationButtons
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // Step indicator
            HStack(spacing: 8) {
                ForEach(1...totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? DesignSystem.Colors.accentPrimary : Color.white.opacity(0.3))
                        .frame(width: 10, height: 10)
                }
                Text("Step \(currentStep) of \(totalSteps)")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            // Skip button
            Button("Skip Setup") {
                model.completeSetupWizard()
            }
            .buttonStyle(.plain)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    // MARK: - Step 1: Photos Permission

    private var photosPermissionStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(DesignSystem.Colors.accentPrimary)

            VStack(spacing: 8) {
                Text("Photos Library Access")
                    .font(DesignSystem.Typography.header)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("ImmiBridge needs access to your Photos library to back up your photos and videos.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            // Permission status
            VStack(spacing: 16) {
                StatusBadge(
                    kind: photosStatusKind,
                    text: model.photosConnectionText
                )

                if model.photosConnectionText == "Permission Needed" {
                    Button("Grant Access") {
                        model.requestPhotosAccess()
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 44))
                    .frame(width: 200)
                } else if model.photosConnectionText == "No Access" {
                    VStack(spacing: 8) {
                        Text("Access was denied. Open System Settings to grant access.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .multilineTextAlignment(.center)

                        Button("Open System Settings") {
                            model.openPhotosPrivacySettings()
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 44))
                        .frame(width: 200)
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 40)
    }

    private var photosStatusKind: StatusBadge.Kind {
        switch model.photosConnectionText {
        case "Connected (Library)":
            return .success
        case "Permission Needed":
            return .warning
        case "No Access":
            return .muted
        default:
            return .info
        }
    }

    // MARK: - Step 2: Immich Configuration

    private var immichConfigStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "server.rack")
                .font(.system(size: 64))
                .foregroundStyle(DesignSystem.Colors.accentSecondary)

            VStack(spacing: 8) {
                Text("Connect to Immich")
                    .font(DesignSystem.Typography.header)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Enter your Immich server URL and API key to enable cloud backup.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server URL")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    TextField("https://your-immich-server.com", text: Binding(
                        get: { model.immichServerURL },
                        set: { model.setImmichServerURL($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)
                    .onSubmit {
                        model.normalizeImmichURL()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    HStack(spacing: 8) {
                        SecureField("Paste your API key", text: $model.immichApiKey)
                            .textFieldStyle(.roundedBorder)
                        if model.immichApiKey.isEmpty && !model.immichServerURL.isEmpty {
                            Button("Get API Key") {
                                model.openImmichApiKeysPage()
                            }
                            .font(.system(.body, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(DesignSystem.Colors.cardBackground)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .cornerRadius(6)
                        }
                    }
                    .frame(width: 350)
                }

                // Connection status
                HStack(spacing: 12) {
                    StatusBadge(
                        kind: immichStatusKind,
                        text: model.immichTestStatus
                    )

                    if !model.immichServerURL.isEmpty && !model.immichApiKey.isEmpty {
                        Button {
                            model.testImmich()
                        } label: {
                            HStack(spacing: 6) {
                                if model.immichTestStatus == "Testing…" {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                                Text("Test Connection")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 36))
                        .frame(width: 150)
                        .disabled(model.immichTestStatus == "Testing…")
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 40)
    }

    private var immichStatusKind: StatusBadge.Kind {
        if model.immichIsConnected {
            return .success
        }
        switch model.immichTestStatus {
        case "Testing…":
            return .info
        case "Not tested":
            return .muted
        default:
            return .warning
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack(spacing: 16) {
            if currentStep > 1 {
                Button("Back") {
                    withAnimation {
                        currentStep -= 1
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 120)
            }

            Spacer()

            if currentStep < totalSteps {
                Button("Next") {
                    withAnimation {
                        currentStep += 1
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 120)
            } else {
                Button("Finish") {
                    model.completeSetupWizard()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 120)
            }
        }
    }
}

#Preview {
    SetupWizardView()
        .environmentObject(PhotoBackupViewModel())
}
