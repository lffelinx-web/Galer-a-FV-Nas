import SwiftUI

/// Ir a fecha: a calendar where days with photos carry a dot. Choosing a day opens it in
/// the mosaic; a day without photos opens the closest earlier one.
struct DateJumpSheet: View {
    let items: [GalleryItem]
    var onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var days: Set<Int> = []
    @State private var years: [Int] = []
    @State private var month = Date()
    @State private var ready = false

    private static let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "es_MX")
        calendar.firstWeekday = 2
        return calendar
    }()
    private var calendar: Calendar { Self.calendar }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if ready {
                    monthHeader
                    weekdays
                    grid
                    Spacer(minLength: 0)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background(AppBackground())
            .navigationTitle("Ir a fecha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hoy") { month = firstOfMonth(Date()) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        let items = self.items
        let calendar = self.calendar
        let (keys, years, newest) = await Task.detached(priority: .userInitiated) { () -> (Set<Int>, [Int], Date?) in
            var keys = Set<Int>()
            var years = Set<Int>()
            for item in items {
                let c = calendar.dateComponents([.year, .month, .day], from: item.date)
                guard let y = c.year, let m = c.month, let d = c.day else { continue }
                keys.insert(y * 10_000 + m * 100 + d)
                years.insert(y)
            }
            return (keys, years.sorted(by: >), items.first?.date)
        }.value
        days = keys
        self.years = years
        month = firstOfMonth(newest ?? Date())
        ready = true
    }

    private var monthHeader: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("Mes anterior")
            Spacer()
            Menu {
                ForEach(years, id: \.self) { year in
                    Button(String(year)) { setYear(year) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Timeline.format(month, "LLLL y", calendar: calendar)).font(.title3.bold()).foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(Palette.secondary)
                }
            }
            .accessibilityHint("Elige el año")
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("Mes siguiente")
        }
        .foregroundStyle(Palette.accent)
    }

    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(["L", "M", "M", "J", "V", "S", "D"].indices, id: \.self) { index in
                Text(["L", "M", "M", "J", "V", "S", "D"][index]).font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let first = month
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let y = calendar.component(.year, from: first), m = calendar.component(.month, from: first)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
            ForEach(0..<(offset + count), id: \.self) { cell in
                if cell < offset {
                    Color.clear.frame(height: 44)
                } else {
                    let day = cell - offset + 1
                    let hasPhotos = days.contains(y * 10_000 + m * 100 + day)
                    Button {
                        if let date = calendar.date(from: DateComponents(year: y, month: m, day: day, hour: 23, minute: 59)) {
                            onPick(date)
                            dismiss()
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text("\(day)").font(.body.weight(hasPhotos ? .semibold : .regular))
                                .foregroundStyle(hasPhotos ? Palette.ink : Palette.secondary.opacity(0.6))
                            Circle().fill(hasPhotos ? Palette.accent : .clear).frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(hasPhotos ? Palette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("\(day)" + (hasPhotos ? ", con fotos" : ""))
                }
            }
        }
    }

    private func firstOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func shift(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next }
    }

    private func setYear(_ year: Int) {
        var components = calendar.dateComponents([.year, .month], from: month)
        components.year = year
        if let date = calendar.date(from: components) { month = date }
    }
}
