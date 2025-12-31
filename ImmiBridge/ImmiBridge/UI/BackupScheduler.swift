import Foundation
import Combine
import SwiftUI

@MainActor
final class BackupScheduler: ObservableObject {
    enum ScheduleType: String, CaseIterable, Codable, Identifiable {
        case disabled = "disabled"
        case interval = "interval"
        case scheduled = "scheduled"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .disabled: return "Disabled"
            case .interval: return "Every X Hours"
            case .scheduled: return "Scheduled"
            }
        }
    }

    /// Represents days of the week (1=Sunday through 7=Saturday, matching Calendar.component(.weekday))
    enum Weekday: Int, CaseIterable, Identifiable, Codable {
        case sunday = 1
        case monday = 2
        case tuesday = 3
        case wednesday = 4
        case thursday = 5
        case friday = 6
        case saturday = 7

        var id: Int { rawValue }

        var shortName: String {
            switch self {
            case .sunday: return "Sun"
            case .monday: return "Mon"
            case .tuesday: return "Tue"
            case .wednesday: return "Wed"
            case .thursday: return "Thu"
            case .friday: return "Fri"
            case .saturday: return "Sat"
            }
        }

        var fullName: String {
            switch self {
            case .sunday: return "Sunday"
            case .monday: return "Monday"
            case .tuesday: return "Tuesday"
            case .wednesday: return "Wednesday"
            case .thursday: return "Thursday"
            case .friday: return "Friday"
            case .saturday: return "Saturday"
            }
        }
    }

    // MARK: - Published Properties

    @Published var scheduleType: ScheduleType = .disabled {
        didSet {
            saveSettings()
            reschedule()
        }
    }

    @Published var intervalHours: Int = 6 {
        didSet {
            saveSettings()
            if scheduleType == .interval {
                reschedule()
            }
        }
    }

    @Published var scheduledHour: Int = 2 {
        didSet {
            // Clamp to valid range
            if scheduledHour < 0 { scheduledHour = 0 }
            if scheduledHour > 23 { scheduledHour = 23 }
            saveSettings()
            if scheduleType == .scheduled {
                reschedule()
            }
        }
    }

    @Published var scheduledMinute: Int = 0 {
        didSet {
            // Clamp to valid range
            if scheduledMinute < 0 { scheduledMinute = 0 }
            if scheduledMinute > 59 { scheduledMinute = 59 }
            saveSettings()
            if scheduleType == .scheduled {
                reschedule()
            }
        }
    }

    @Published var selectedDays: Set<Weekday> = Set(Weekday.allCases) {
        didSet {
            saveSettings()
            if scheduleType == .scheduled {
                reschedule()
            }
        }
    }

    @Published var skipOnBattery: Bool = true {
        didSet {
            saveSettings()
        }
    }

    @Published private(set) var nextBackupDate: Date?
    @Published private(set) var lastBackupDate: Date?

    // MARK: - Computed Properties

    var isEnabled: Bool {
        scheduleType != .disabled
    }

    var formattedTime: String {
        String(format: "%02d:%02d", scheduledHour, scheduledMinute)
    }

    var scheduleDescription: String {
        switch scheduleType {
        case .disabled:
            return "Backups are not scheduled"
        case .interval:
            return "Every \(intervalHours) hour\(intervalHours == 1 ? "" : "s")"
        case .scheduled:
            if selectedDays.isEmpty {
                return "No days selected"
            } else if selectedDays.count == 7 {
                return "Daily at \(formattedTime)"
            } else if selectedDays == [.monday, .tuesday, .wednesday, .thursday, .friday] {
                return "Weekdays at \(formattedTime)"
            } else if selectedDays == [.saturday, .sunday] {
                return "Weekends at \(formattedTime)"
            } else {
                let sortedDays = selectedDays.sorted { $0.rawValue < $1.rawValue }
                let dayNames = sortedDays.map { $0.shortName }.joined(separator: ", ")
                return "\(dayNames) at \(formattedTime)"
            }
        }
    }

    // MARK: - Private Properties

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard
    private weak var viewModel: PhotoBackupViewModel?
    private var isLoadingSettings = false

    // MARK: - Initialization

    init() {
        loadSettings()
        observeWakeNotification()
    }

    // MARK: - Public Methods

    func bind(to viewModel: PhotoBackupViewModel) {
        self.viewModel = viewModel

        // Observe backup completion to reschedule and update lastBackupDate
        viewModel.$isRunning
            .removeDuplicates()
            .dropFirst() // Skip initial value
            .sink { [weak self] isRunning in
                guard let self = self else { return }
                if !isRunning {
                    // Backup just finished
                    self.handleBackupCompleted()
                }
            }
            .store(in: &cancellables)

        // Initial schedule
        reschedule()
    }

    func triggerManualBackup() {
        guard let viewModel = viewModel, !viewModel.isRunning else { return }

        if viewModel.hasResumableSession {
            viewModel.resume()
        } else {
            viewModel.start()
        }
    }

    func toggleDay(_ day: Weekday) {
        if selectedDays.contains(day) {
            selectedDays.remove(day)
        } else {
            selectedDays.insert(day)
        }
    }

    func selectAllDays() {
        selectedDays = Set(Weekday.allCases)
    }

    func selectWeekdays() {
        selectedDays = [.monday, .tuesday, .wednesday, .thursday, .friday]
    }

    func selectWeekends() {
        selectedDays = [.saturday, .sunday]
    }

    func clearDays() {
        selectedDays = []
    }

    // MARK: - Private Methods

    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }

        if let raw = defaults.string(forKey: "scheduleType"),
           let type = ScheduleType(rawValue: raw) {
            scheduleType = type
        }

        let storedInterval = defaults.integer(forKey: "scheduleIntervalHours")
        if storedInterval > 0 {
            intervalHours = storedInterval
        }

        let storedHour = defaults.integer(forKey: "scheduledTimeHour")
        if storedHour >= 0 && storedHour < 24 {
            scheduledHour = storedHour
        }

        let storedMinute = defaults.integer(forKey: "scheduledTimeMinute")
        if storedMinute >= 0 && storedMinute < 60 {
            scheduledMinute = storedMinute
        }

        // Load selected days
        if let daysData = defaults.data(forKey: "scheduledDays"),
           let days = try? JSONDecoder().decode(Set<Weekday>.self, from: daysData) {
            selectedDays = days
        }

        skipOnBattery = defaults.object(forKey: "skipOnBattery") as? Bool ?? true

        if let lastDate = defaults.object(forKey: "lastBackupDate") as? Date {
            lastBackupDate = lastDate
        }
    }

    private func saveSettings() {
        guard !isLoadingSettings else { return }
        defaults.set(scheduleType.rawValue, forKey: "scheduleType")
        defaults.set(intervalHours, forKey: "scheduleIntervalHours")
        defaults.set(scheduledHour, forKey: "scheduledTimeHour")
        defaults.set(scheduledMinute, forKey: "scheduledTimeMinute")
        defaults.set(skipOnBattery, forKey: "skipOnBattery")

        // Save selected days
        if let daysData = try? JSONEncoder().encode(selectedDays) {
            defaults.set(daysData, forKey: "scheduledDays")
        }

        if let lastDate = lastBackupDate {
            defaults.set(lastDate, forKey: "lastBackupDate")
        }
    }

    private func reschedule() {
        guard !isLoadingSettings else { return }
        timer?.invalidate()
        timer = nil

        guard scheduleType != .disabled else {
            nextBackupDate = nil
            return
        }

        let next = calculateNextBackupDate()
        nextBackupDate = next

        guard let next = next else { return }

        let interval = next.timeIntervalSinceNow
        if interval <= 0 {
            // Overdue, trigger now
            triggerScheduledBackup()
            return
        }

        // Schedule timer
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerScheduledBackup()
            }
        }
    }

    private func calculateNextBackupDate() -> Date? {
        let now = Date()

        switch scheduleType {
        case .disabled:
            return nil

        case .interval:
            if let last = lastBackupDate {
                return last.addingTimeInterval(Double(intervalHours) * 3600)
            } else {
                // No previous backup, schedule for intervalHours from now
                return now.addingTimeInterval(Double(intervalHours) * 3600)
            }

        case .scheduled:
            guard !selectedDays.isEmpty else { return nil }
            return nextOccurrence(hour: scheduledHour, minute: scheduledMinute, days: selectedDays, after: now)
        }
    }

    private func nextOccurrence(hour: Int, minute: Int, days: Set<Weekday>, after date: Date) -> Date? {
        let calendar = Calendar.current

        // Check up to 8 days ahead (covers all cases)
        for dayOffset in 0...7 {
            guard let candidateDate = calendar.date(byAdding: .day, value: dayOffset, to: date) else {
                continue
            }

            let weekday = calendar.component(.weekday, from: candidateDate)
            guard let weekdayEnum = Weekday(rawValue: weekday), days.contains(weekdayEnum) else {
                continue
            }

            // Build the candidate time on this day
            var components = calendar.dateComponents([.year, .month, .day], from: candidateDate)
            components.hour = hour
            components.minute = minute
            components.second = 0

            guard let candidate = calendar.date(from: components) else {
                continue
            }

            // If it's today, make sure the time hasn't passed
            if candidate > date {
                return candidate
            }
        }

        return nil
    }

    private func triggerScheduledBackup() {
        guard let viewModel = viewModel else { return }

        // Don't trigger if already running
        if viewModel.isRunning {
            // Reschedule for later
            reschedule()
            return
        }

        // Check power state
        if skipOnBattery && !PowerManager.isOnACPower() {
            // Skip this backup, reschedule
            NotificationManager.shared.sendBackupSkipped(reason: "Mac is on battery power")
            reschedule()
            return
        }

        // Trigger backup
        NotificationManager.shared.sendBackupStarted()

        if viewModel.hasResumableSession {
            viewModel.resume()
        } else {
            viewModel.start()
        }
    }

    private func handleBackupCompleted() {
        lastBackupDate = Date()
        saveSettings()

        // Send completion notification
        if let viewModel = viewModel {
            NotificationManager.shared.sendBackupCompleted(
                uploaded: viewModel.uploadedCount,
                skipped: viewModel.skippedCount,
                errors: viewModel.errorCount
            )
        }

        // Reschedule next backup
        reschedule()
    }

    private func observeWakeNotification() {
        NotificationCenter.default.addObserver(
            forName: .systemDidWake,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkMissedBackups()
            }
        }
    }

    private func checkMissedBackups() {
        guard scheduleType != .disabled else { return }

        if let next = nextBackupDate, next <= Date() {
            // Missed a scheduled backup, trigger now
            triggerScheduledBackup()
        } else {
            // Reschedule in case timer was invalidated during sleep
            reschedule()
        }
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
