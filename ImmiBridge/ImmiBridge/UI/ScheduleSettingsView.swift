import SwiftUI

struct ScheduleSettingsView: View {
    @EnvironmentObject var scheduler: BackupScheduler

    var body: some View {
        BackupCardView(
            title: "Schedule",
            badge: scheduleBadge,
            isDisabled: false
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Schedule type picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Schedule Type")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Picker("", selection: $scheduler.scheduleType) {
                        ForEach(BackupScheduler.ScheduleType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Schedule configuration based on type
                if scheduler.scheduleType == .interval {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Backup Interval")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        HStack {
                            Text("Every")
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Stepper(value: $scheduler.intervalHours, in: 1...48) {
                                Text("\(scheduler.intervalHours)")
                                    .font(.system(.title3, design: .rounded).bold())
                                    .foregroundStyle(DesignSystem.Colors.accentPrimary)
                            }
                            .frame(width: 100)
                            Text("hour\(scheduler.intervalHours == 1 ? "" : "s")")
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Spacer()
                        }
                    }
                }

                if scheduler.scheduleType == .scheduled {
                    // Time input (HH:MM)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Time (24-hour)")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        HStack(spacing: 4) {
                            TextField("HH", value: $scheduler.scheduledHour, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .multilineTextAlignment(.center)
                            Text(":")
                                .font(.system(.title2, design: .monospaced).bold())
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            TextField("MM", value: $scheduler.scheduledMinute, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .multilineTextAlignment(.center)
                            Spacer()
                            Text(scheduler.formattedTime)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }

                    // Day selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Days")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        // Day buttons
                        HStack(spacing: 6) {
                            ForEach(BackupScheduler.Weekday.allCases) { day in
                                DayToggleButton(
                                    day: day,
                                    isSelected: scheduler.selectedDays.contains(day),
                                    action: { scheduler.toggleDay(day) }
                                )
                            }
                        }

                        // Quick select buttons
                        HStack(spacing: 8) {
                            Button("All") { scheduler.selectAllDays() }
                                .buttonStyle(QuickSelectButtonStyle())
                            Button("Weekdays") { scheduler.selectWeekdays() }
                                .buttonStyle(QuickSelectButtonStyle())
                            Button("Weekends") { scheduler.selectWeekends() }
                                .buttonStyle(QuickSelectButtonStyle())
                            Button("Clear") { scheduler.clearDays() }
                                .buttonStyle(QuickSelectButtonStyle())
                            Spacer()
                        }
                    }
                }

                // Skip on battery toggle
                if scheduler.scheduleType != .disabled {
                    Toggle(isOn: $scheduler.skipOnBattery) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip on Battery")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("Don't run scheduled backups when unplugged")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                // Next backup info
                if scheduler.isEnabled {
                    Divider()
                        .overlay(DesignSystem.Colors.separator)

                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(DesignSystem.Colors.accentPrimary)
                        if let next = scheduler.nextBackupDate {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next Backup")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                Text(next, style: .relative)
                                    .font(.system(.body, design: .rounded).bold())
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text(next, format: .dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        } else if scheduler.scheduleType == .scheduled && scheduler.selectedDays.isEmpty {
                            Text("No days selected")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(.orange)
                        } else {
                            Text("Calculating next backup...")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                    }
                }

                // Last backup info
                if let last = scheduler.lastBackupDate {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(DesignSystem.Colors.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last Backup")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Text(last, style: .relative)
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var scheduleBadge: StatusBadge {
        switch scheduler.scheduleType {
        case .disabled:
            return StatusBadge(kind: .muted, text: "Disabled")
        case .interval, .scheduled:
            return StatusBadge(kind: .info, text: scheduler.scheduleDescription)
        }
    }
}

struct DayToggleButton: View {
    let day: BackupScheduler.Weekday
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(day.shortName)
                .font(.system(.caption, design: .rounded).bold())
                .foregroundStyle(isSelected ? .white : DesignSystem.Colors.textSecondary)
                .frame(width: 36, height: 32)
                .background(isSelected ? DesignSystem.Colors.accentPrimary : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? Color.clear : Color.white.opacity(0.1), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

struct QuickSelectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption2, design: .rounded))
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

#Preview {
    ScheduleSettingsView()
        .environmentObject(BackupScheduler())
        .padding()
        .background(DesignSystem.Colors.windowBackground)
}
