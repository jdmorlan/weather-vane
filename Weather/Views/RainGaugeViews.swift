//
//  RainGaugeViews.swift
//
//  LOGGING YOUR OWN RAIN GAUGE, and seeing what it says about the station.
//
//  The sheet works the way a gauge reading does: pick the days since you last
//  emptied it, see what the station measured on each, type what the gauge
//  held, and for each day keep the station's figure or take yours. Days kept
//  come off the gauge's total; the remainder goes to the days you didn't keep.
//  See `GaugeSplit` for the rules, and `RainLog` for why it's built this way.
//

import SwiftUI
import WeatherKit

/// The gauge sheet. New, or editing an existing reading.
struct GaugeEntrySheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RainLogStore
    @Environment(\.dismiss) private var dismiss

    let timeZone: TimeZone
    var editing: GaugeReading? = nil

    @State private var from = Date()
    @State private var to = Date()
    @State private var totalText = ""
    @State private var note = ""
    /// Days the person is taking for themselves; every other day keeps the
    /// station's figure. Starts with the last day — the usual case is "the
    /// station was right until today".
    @State private var mine: Set<String> = []
    @State private var typed: [String: String] = [:]
    @State private var station: [String: Double] = [:]
    @State private var loadedSpan: String?
    @State private var error: String?

    private static let maxDays = 14

    private func key(_ date: Date) -> String { DayKey.string(for: date, timeZone: timeZone) }

    private var days: [String] {
        let start = key(min(from, to)), end = key(max(from, to))
        var out: [String] = []
        var k = start
        while k <= end, out.count < Self.maxDays {
            out.append(k)
            guard let next = DayKey.step(k, by: 1) else { break }
            k = next
        }
        return out
    }

    private var spanKey: String { "\(days.first ?? "")|\(days.last ?? "")" }

    private var total: Double? { Double(totalText.replacingOccurrences(of: ",", with: ".")) }

    private var resolution: Result<[GaugeReading.Day], GaugeSplit.Problem>? {
        guard let total, loadedSpan == spanKey else { return nil }
        let keep = Set(days.filter { !mine.contains($0) })
        let typedValues = typed.compactMapValues { Double($0.replacingOccurrences(of: ",", with: ".")) }
            .filter { mine.contains($0.key) }
        return GaugeSplit.resolve(total: total, station: days.map { ($0, station[$0]) },
                                  keep: keep, typed: typedValues)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("From", selection: $from, in: ...Date(), displayedComponents: .date)
                    DatePicker("To", selection: $to, in: ...Date(), displayedComponents: .date)
                    Text("The days since you last emptied the gauge — up to \(Self.maxDays).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("What your gauge held") {
                    HStack {
                        TextField("Total", text: $totalText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        Text("inches").foregroundStyle(.secondary)
                    }
                }
                Section {
                    if loadedSpan != spanKey {
                        if let error {
                            Text("Couldn't read the station's rain: \(error)").foregroundStyle(.secondary)
                        } else {
                            ProgressView("Reading what the station measured…")
                        }
                    } else {
                        ForEach(days, id: \.self) { day in dayRow(day) }
                    }
                } header: {
                    Text("Each day")
                } footer: {
                    Text("Keep the station's figure for the days it got right. The rest of your total goes to the days you take — type an amount for any you know, and the last one gets what's left.")
                }
                Section {
                    resultView
                }
                Section("Note") {
                    TextField("Optional — \"emptied at 5pm\"", text: $note)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing == nil ? "Log your rain gauge" : "Edit gauge reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .task(id: spanKey) { await loadStation() }
            .onAppear(perform: prefill)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func dayRow(_ day: String) -> some View {
        let isMine = mine.contains(day)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(WeatherAlmanac.dayLabel(day)).font(.body.weight(.medium))
                Spacer()
                Text(station[day].map { String(format: "station %.2f″", $0) } ?? "station: no record")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Picker("", selection: Binding(get: { isMine }, set: { take in
                if take { mine.insert(day) } else { mine.remove(day); typed[day] = nil }
            })) {
                Text("Keep the station's").tag(false)
                Text("Use my gauge").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if isMine && mine.count > 1 {
                HStack {
                    TextField("Amount, or blank for what's left", text: Binding(
                        get: { typed[day] ?? "" }, set: { typed[day] = $0.isEmpty ? nil : $0 }))
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text("in").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var resultView: some View {
        switch resolution {
        case .none:
            Text(total == nil ? "Enter what the gauge held to see how it splits." : "Waiting for the station's figures…")
                .foregroundStyle(.secondary)
        case .success(let split):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(split) { d in
                    HStack {
                        Text(WeatherAlmanac.dayLabel(d.day))
                        Spacer()
                        Text(String(format: "%.2f″", d.amount)).monospacedDigit()
                        Text(d.source == .station ? "station's" : "yours")
                            .font(.caption).foregroundStyle(d.source == .station ? Color.secondary : Color.blue)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Text(String(format: "Adds up to %.2f″ ✓", split.reduce(0) { $0 + $1.amount }))
                    .font(.caption).foregroundStyle(.green)
            }
        case .failure(let problem):
            Text(message(problem)).foregroundStyle(.orange)
        }
    }

    private func message(_ problem: GaugeSplit.Problem) -> String {
        switch problem {
        case .keptExceedTotal(let kept, let total):
            return String(format: "The days you kept and typed already add up to %.2f″, more than the gauge's %.2f″.", kept, total)
        case .nothingLeftToAssign(let difference):
            return String(format: "Every day is kept at the station's figure, but your total is %.2f″ %@. Take at least one day as yours.",
                          abs(difference), difference > 0 ? "more" : "less")
        case .emptySpan:
            return "Pick at least one day."
        }
    }

    private var canSave: Bool {
        if case .success = resolution { return true }
        return false
    }

    private func prefill() {
        if let r = editing {
            from = DayKey.date(from: r.from, timeZone: timeZone) ?? Date()
            to = DayKey.date(from: r.to, timeZone: timeZone) ?? Date()
            totalText = String(format: "%.2f", r.total)
            note = r.note
            mine = Set(r.days.filter { $0.source != .station }.map(\.day))
            typed = Dictionary(uniqueKeysWithValues: r.days.filter { $0.source == .gauge }
                .map { ($0.day, String(format: "%.2f", $0.amount)) })
        } else {
            // Yesterday through today, taking today: the reading you came to log.
            to = Date()
            from = Calendar.current.date(byAdding: .day, value: -1, to: to) ?? to
            mine = [key(to)]
        }
    }

    private func loadStation() async {
        let span = spanKey, wanted = days
        error = nil
        // Editing: the station's figures as they were when the reading was made.
        if let r = editing, span == "\(r.from)|\(r.to)" {
            station = Dictionary(uniqueKeysWithValues: r.days.compactMap { d in d.station.map { (d.day, $0) } })
            loadedSpan = span
            return
        }
        do {
            let client = TempestClient(token: settings.tempestToken, stationID: settings.tempestStationID)
            let fetched = try await client.dailyRain(days: wanted, timeZone: timeZone)
            guard !Task.isCancelled, span == spanKey else { return }
            station = fetched
            loadedSpan = span
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard case .success(let split) = resolution, let total, let first = days.first, let last = days.last else { return }
        var reading = editing ?? GaugeReading(from: first, to: last, total: total, days: split)
        reading.from = first
        reading.to = last
        reading.total = total
        reading.days = split
        reading.note = note
        store.save(reading)
        dismiss()
    }
}

/// The log, on the Rain page and the phone's Rain tab: every reading, what it
/// changed, and what the readings say about the station's rain sensor.
struct RainGaugeCard: View {
    @EnvironmentObject private var store: RainLogStore
    @EnvironmentObject private var settings: AppSettings
    let timeZone: TimeZone

    @State private var adding = false
    @State private var editing: GaugeReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let share = store.log.stationShare {
                Text(sensorLine(share))
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("When the station misses rain, log what your own gauge caught. Where you correct a day, your number is used in every total, and the station's stays beside it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.log.live) { reading in
                row(reading)
                Divider().opacity(0.4)
            }

            Button {
                adding = true
            } label: {
                Label("Log your rain gauge", systemImage: "plus.circle.fill")
            }
        }
        // Handed in explicitly, as the setup sheet's are: a sheet is its own
        // presentation and this app doesn't lean on it inheriting them.
        .sheet(isPresented: $adding) {
            GaugeEntrySheet(timeZone: timeZone).environmentObject(store).environmentObject(settings)
        }
        .sheet(item: $editing) { reading in
            GaugeEntrySheet(timeZone: timeZone, editing: reading).environmentObject(store).environmentObject(settings)
        }
    }

    /// "On the 1 day you corrected, the station caught 0.10″ of your 1.43″ (7%)."
    private func sensorLine(_ s: (station: Double, gauge: Double, days: Int)) -> String {
        let pct = s.gauge > 0 ? Int((s.station / s.gauge * 100).rounded()) : 0
        return String(format: "On the %d %@ you corrected, the station caught %.2f″ of your gauge's %.2f″ — %d%%.",
                      s.days, s.days == 1 ? "day" : "days", s.station, s.gauge, pct)
    }

    private func row(_ r: GaugeReading) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "drop.fill").foregroundStyle(.blue).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(StretchStory.span(r.from, r.from == r.to ? nil : r.to)) · \(String(format: "%.2f″", r.total)) in the gauge")
                    .font(.callout.weight(.semibold))
                Text(r.days.map { d in
                    "\(WeatherAlmanac.dayLabel(d.day)) \(String(format: "%.2f″", d.amount)) \(d.source == .station ? "(station's)" : "(yours)")"
                }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
                if !r.note.isEmpty {
                    Text(r.note).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Edit") { editing = r }
                Button("Delete", role: .destructive) { store.delete(r.id) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
