import SwiftUI

/// Date display with prev/next day navigation arrows.
/// Optionally shows a display picker when multiple displays have data.
struct DayNavigator: View {
    let dateString: String
    let onPrevious: () -> Void
    let onNext: () -> Void
    let canGoNext: Bool

    // Multi-display (optional — hidden when empty or single display)
    var displayIDs: [CGDirectDisplayID] = []
    var selectedDisplayID: CGDirectDisplayID?
    var onSelectDisplay: ((CGDirectDisplayID) -> Void)?

    var body: some View {
        HStack {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Previous day")

            Spacer()

            VStack(spacing: 4) {
                Text(dateString)
                    .font(.headline)

                if displayIDs.count > 1, let onSelectDisplay {
                    Picker("Display", selection: Binding(
                        get: { selectedDisplayID ?? displayIDs.first ?? CGMainDisplayID() },
                        set: { onSelectDisplay($0) }
                    )) {
                        ForEach(Array(displayIDs.enumerated()), id: \.element) { index, id in
                            Text("Display \(index + 1)").tag(id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
            }

            Spacer()

            Button(action: onNext) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!canGoNext)
            .help("Next day")
        }
    }
}
